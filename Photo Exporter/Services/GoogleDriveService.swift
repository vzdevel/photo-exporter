//
//  GoogleDriveService.swift
//  Photo Exporter
//

import Foundation
import Photos
import UIKit

/// Service managing Google Drive API interactions (listing folders, checking conflicts, and uploading media)
final class GoogleDriveService {
    static let shared = GoogleDriveService()

    private let authService = GoogleDriveAuthService.shared
    private let libraryService = PhotoLibraryService.shared
    private let exifService = ExifMetadataService.shared

    /// Dedicated session configured with long timeouts and waitsForConnectivity to avoid timeouts on slow networks or large files
    private lazy var uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300.0 // 5 minutes inactivity timeout
        config.timeoutIntervalForResource = 7200.0 // 2 hours resource timeout
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private let recentRangeCache = GoogleDriveRangeCache()
    private let rangeStreamDelegate = GoogleDriveRangeStreamDelegate()
    private var foregroundObserver: NSObjectProtocol?

    private lazy var streamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 3600.0
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.name = "com.photoexporter.gdrive.rangestream"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return URLSession(configuration: config, delegate: rangeStreamDelegate, delegateQueue: queue)
    }()

    private init() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.uploadSession.flush {}
            self?.streamingSession.flush {}
        }
    }

    private func performAuthorizedData(
        for request: URLRequest,
        accountID: String?,
        explicitToken: String? = nil
    ) async throws -> (Data, HTTPURLResponse, String) {
        var activeToken: String
        if let explicitToken, !explicitToken.isEmpty {
            activeToken = explicitToken
        } else {
            activeToken = try await authService.getValidAccessToken(for: accountID)
        }

        var authorizedRequest = request
        authorizedRequest.setValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await GoogleDriveAuthService.performResilientDataRequest(authorizedRequest)

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 401,
           explicitToken == nil {
            activeToken = try await authService.getValidAccessToken(for: accountID, forceRefresh: true)
            authorizedRequest.setValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
            (data, response) = try await GoogleDriveAuthService.performResilientDataRequest(authorizedRequest)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse, activeToken)
    }

    // MARK: - Folder Navigation & Management

    /// List subfolders inside a specific parent folder ID (default is "root")
    func listFolders(in parentFolderId: String = "root", accountID: String? = nil) async throws -> [GoogleDriveFolder] {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let query = "'\(parentFolderId)' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id, name, modifiedTime)"),
            URLQueryItem(name: "orderBy", value: "name"),
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
        ]

        guard let url = components.url else {
            throw NSError(domain: "GoogleDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        let request = URLRequest(url: url)
        let (data, httpResponse, _) = try await performAuthorizedData(for: request, accountID: accountID)
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GoogleDrive", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to list folders: \(errorText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else {
            return []
        }

        let dateFormatter = ISO8601DateFormatter()
        var folders: [GoogleDriveFolder] = []

        for dict in files {
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String else { continue }
            let modTimeStr = dict["modifiedTime"] as? String
            let modTime = modTimeStr != nil ? dateFormatter.date(from: modTimeStr!) : nil
            folders.append(GoogleDriveFolder(id: id, name: name, modifiedTime: modTime))
        }

        return folders
    }

    /// Lists subfolders along with supported image and video counts in the given parent folder
    func listFolderContents(in parentFolderId: String = "root", accountID: String? = nil) async throws -> (folders: [GoogleDriveFolder], imageCount: Int, videoCount: Int) {
        var activeToken: String? = nil

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        var folders: [GoogleDriveFolder] = []
        var mediaFilenames: [String] = []
        var pageToken: String? = nil

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            let query = "'\(parentFolderId)' in parents and trashed = false"
            var queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "nextPageToken, files(id, name, mimeType, modifiedTime, size)"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems

            guard let url = components.url else {
                throw NSError(domain: "GoogleDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }

            let request = URLRequest(url: url)
            let (data, httpResponse, usedToken) = try await performAuthorizedData(for: request, accountID: accountID, explicitToken: activeToken)
            activeToken = usedToken
            guard httpResponse.statusCode == 200 else {
                let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "GoogleDrive", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to list folders: \(errorText)"])
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [[String: Any]] else {
                break
            }

            for dict in files {
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else { continue }
                let mimeType = dict["mimeType"] as? String ?? ""

                if mimeType == "application/vnd.google-apps.folder" {
                    let modTimeStr = dict["modifiedTime"] as? String
                    let modTime = modTimeStr.flatMap { dateFormatter.date(from: $0) ?? fallbackFormatter.date(from: $0) }
                    folders.append(GoogleDriveFolder(id: id, name: name, modifiedTime: modTime))
                } else {
                    let size: Int64
                    if let szStr = dict["size"] as? String {
                        size = Int64(szStr) ?? 0
                    } else if let szNum = dict["size"] as? NSNumber {
                        size = szNum.int64Value
                    } else {
                        size = 0
                    }
                    if size > 0 {
                        mediaFilenames.append(name)
                    }
                }
            }

            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil

        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let mediaCounts = PhotoItem.countMediaFilenames(mediaFilenames)
        return (folders, mediaCounts.images, mediaCounts.videos)
    }

    /// Create a new subfolder in Google Drive
    func createFolder(named name: String, in parentFolderId: String = "root", accountID: String? = nil, accessToken: String? = nil) async throws -> GoogleDriveFolder {
        let token: String
        if let at = accessToken, !at.isEmpty {
            token = at
        } else {
            token = try await authService.getValidAccessToken(for: accountID)
        }

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?supportsAllDrives=true")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentFolderId]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await GoogleDriveAuthService.performResilientDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, (200...201).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GoogleDrive", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create folder: \(errorText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let folderName = json["name"] as? String else {
            throw NSError(domain: "GoogleDrive", code: -4, userInfo: [NSLocalizedDescriptionKey: "Malformed folder creation response"])
        }

        return GoogleDriveFolder(id: id, name: folderName, modifiedTime: Date())
    }

    /// Resolve parent folder hierarchy for a folder up to root
    func resolveFolderHierarchy(for folderId: String, accountID: String? = nil) async -> [GoogleDriveFolderBreadcrumb]? {
        guard folderId != "root" else {
            return [GoogleDriveFolderBreadcrumb(id: "root", name: "My Drive")]
        }

        guard let token = try? await authService.getValidAccessToken(for: accountID) else {
            return nil
        }

        var chain: [GoogleDriveFolderBreadcrumb] = []
        var currentId = folderId
        var visited = Set<String>()

        while currentId != "root" && !visited.contains(currentId) {
            visited.insert(currentId)

            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(currentId)")!
            components.queryItems = [
                URLQueryItem(name: "fields", value: "id,name,parents"),
                URLQueryItem(name: "supportsAllDrives", value: "true")
            ]
            guard let url = components.url else { break }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, response) = try? await GoogleDriveAuthService.performResilientDataRequest(request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  let name = json["name"] as? String else {
                break
            }

            chain.append(GoogleDriveFolderBreadcrumb(id: id, name: name))

            if let parents = json["parents"] as? [String], let firstParent = parents.first, !firstParent.isEmpty {
                currentId = firstParent
            } else {
                break
            }
        }

        chain.append(GoogleDriveFolderBreadcrumb(id: "root", name: "My Drive"))
        return chain.reversed()
    }

    // Cache for subfolder hierarchies (parentFolderId + ":" + path -> folderId)
    private var subfolderHierarchyCache: [String: String] = [:]

    func clearSubfolderCache() {
        subfolderHierarchyCache.removeAll()
    }

    /// Resolves or optionally creates a nested subfolder hierarchy (e.g. "2026/11") under parentFolderId
    func findOrCreateSubfolderHierarchy(
        path: String,
        under parentFolderId: String,
        accountID: String? = nil,
        accessToken: String? = nil,
        createIfMissing: Bool = false
    ) async throws -> String? {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !clean.isEmpty else { return parentFolderId }

        let cacheKey = "\(accountID ?? ""):\(parentFolderId):\(clean)"
        if let cached = subfolderHierarchyCache[cacheKey] {
            return cached
        }

        let components = clean.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var currentParentId = parentFolderId
        let token = try await (accessToken != nil && !accessToken!.isEmpty ? accessToken! : authService.getValidAccessToken(for: accountID))

        for comp in components {
            var urlComponents = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            let escapedComp = comp.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let query = "'\(currentParentId)' in parents and mimeType = 'application/vnd.google-apps.folder' and name = '\(escapedComp)' and trashed = false"
            urlComponents.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "files(id, name)"),
                URLQueryItem(name: "pageSize", value: "10"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
            ]

            guard let url = urlComponents.url else { return nil }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await GoogleDriveAuthService.performResilientDataRequest(request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [[String: Any]] else {
                return nil
            }

            if let existing = files.first, let folderId = existing["id"] as? String {
                currentParentId = folderId
            } else if createIfMissing {
                let newFolder = try await createFolder(named: comp, in: currentParentId, accountID: accountID, accessToken: token)
                currentParentId = newFolder.id
            } else {
                return nil
            }
        }

        subfolderHierarchyCache[cacheKey] = currentParentId
        return currentParentId
    }

    // MARK: - Destination Files & Conflict Checking

    /// Query existing files in the target folder with metadata (modification date, size, and thumbnailLink)
    func fetchDestinationFiles(in folderId: String, subfolderPath: String = "", accountID: String? = nil, accessToken: String? = nil) async throws -> [DestinationFileInfo] {
        try await queryDirectoryContents(
            in: folderId,
            includeFolders: false,
            subfolderPath: subfolderPath,
            accountID: accountID,
            accessToken: accessToken
        ).files
    }

    /// Queries both subfolders and non-empty files in a single Drive listing call.
    func fetchDirectoryEntries(in folderId: String, subfolderPath: String = "", accountID: String? = nil) async throws -> (folders: [GoogleDriveFolder], files: [DestinationFileInfo]) {
        try await queryDirectoryContents(
            in: folderId,
            includeFolders: true,
            subfolderPath: subfolderPath,
            accountID: accountID
        )
    }

    private func queryDirectoryContents(
        in folderId: String,
        includeFolders: Bool,
        subfolderPath: String = "",
        accountID: String? = nil,
        accessToken: String? = nil
    ) async throws -> (folders: [GoogleDriveFolder], files: [DestinationFileInfo]) {
        let explicitToken: String? = (accessToken?.isEmpty == false) ? accessToken : nil
        var allFolders: [GoogleDriveFolder] = []
        var allFiles: [DestinationFileInfo] = []
        var pageToken: String? = nil

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        let query = includeFolders
            ? "'\(folderId)' in parents and trashed = false"
            : "'\(folderId)' in parents and trashed = false and mimeType != 'application/vnd.google-apps.folder'"

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "nextPageToken, files(id, name, mimeType, modifiedTime, size, thumbnailLink)"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
            ]
            if let pToken = pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pToken))
            }
            components.queryItems = queryItems

            guard let url = components.url else { break }
            let request = URLRequest(url: url)

            let (data, httpResponse, _) = try await performAuthorizedData(
                for: request,
                accountID: accountID,
                explicitToken: explicitToken
            )
            guard httpResponse.statusCode == 200 else {
                let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "GoogleDrive", code: -10, userInfo: [NSLocalizedDescriptionKey: "Failed to list folder files: \(errorText)"])
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [[String: Any]] else {
                break
            }

            for dict in files {
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else { continue }

                let modTimeStr = dict["modifiedTime"] as? String
                let modTime = modTimeStr != nil ? (dateFormatter.date(from: modTimeStr!) ?? fallbackFormatter.date(from: modTimeStr!)) : nil
                let mimeType = dict["mimeType"] as? String ?? ""

                if mimeType == "application/vnd.google-apps.folder" {
                    if includeFolders {
                        allFolders.append(GoogleDriveFolder(id: id, name: name, modifiedTime: modTime))
                    }
                    continue
                }

                let size: Int64
                if let szStr = dict["size"] as? String {
                    size = Int64(szStr) ?? 0
                } else if let szNum = dict["size"] as? NSNumber {
                    size = szNum.int64Value
                } else {
                    size = 0
                }

                // Ignore 0-byte destination files and treat them as non-existent so they are simply overridden
                guard size > 0 else { continue }

                let thumbnailLink = dict["thumbnailLink"] as? String

                allFiles.append(DestinationFileInfo(
                    id: id,
                    filename: name,
                    modificationDate: modTime,
                    fileSize: size,
                    thumbnailLink: thumbnailLink,
                    subfolderPath: subfolderPath
                ))
            }

            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil

        return (allFolders, allFiles)
    }

    /// Obtain a valid Bearer token for accessing Google Drive assets (such as thumbnails)
    func getValidAccessToken(for accountID: String?) async throws -> String {
        try await authService.getValidAccessToken(for: accountID)
    }

    /// Query existing files in the target folder to find filenames that conflict with items to export
    func checkConflicts(for items: [PhotoItem], in folderId: String, accountID: String? = nil) async throws -> [String] {
        let token = try await authService.getValidAccessToken(for: accountID)

        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let query = "'\(folderId)' in parents and trashed = false"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id, name, size)"),
            URLQueryItem(name: "pageSize", value: "1000")
        ]

        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await GoogleDriveAuthService.performResilientDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else {
            return []
        }

        let existingFilenames = Set(files.compactMap { file -> String? in
            guard let name = file["name"] as? String else { return nil }
            let size: Int64
            if let szStr = file["size"] as? String {
                size = Int64(szStr) ?? 0
            } else if let szNum = file["size"] as? NSNumber {
                size = szNum.int64Value
            } else {
                size = 0
            }
            // Ignore 0-byte destination files
            guard size > 0 else { return nil }
            return name
        })
        var conflicts: [String] = []

        for item in items {
            if existingFilenames.contains(item.filename) {
                conflicts.append(item.filename)
            }
        }

        return conflicts
    }

    /// Query existing file IDs with a specific name in a folder
    private func fetchExistingFileIDs(named name: String, in folderId: String, token: String, ignoreZeroByte: Bool = false) async throws -> [String] {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let escapedName = name.replacingOccurrences(of: "'", with: "\\'")
        let query = "'\(folderId)' in parents and name = '\(escapedName)' and trashed = false"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id, name, size)")
        ]

        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await GoogleDriveAuthService.performResilientDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else {
            return []
        }

        if ignoreZeroByte {
            return files.compactMap { file in
                let size: Int64
                if let szStr = file["size"] as? String {
                    size = Int64(szStr) ?? 0
                } else if let szNum = file["size"] as? NSNumber {
                    size = szNum.int64Value
                } else {
                    size = 0
                }
                guard size > 0 else { return nil }
                return file["id"] as? String
            }
        }

        return files.compactMap { $0["id"] as? String }
    }

    /// Delete a file by ID
    private func deleteFile(id: String, token: String) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?supportsAllDrives=true")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await GoogleDriveAuthService.performResilientDataRequest(request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "GoogleDrive", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Delete failed: \(errText)"])
        }
    }

    // MARK: - Folder Mode File Operations

    func deleteFile(fileId: String, accountID: String?) async throws {
        let token = try await authService.getValidAccessToken(for: accountID)
        try await deleteFile(id: fileId, token: token)
    }

    func renameFile(fileId: String, newName: String, accountID: String?) async throws {
        let token = try await authService.getValidAccessToken(for: accountID)
        try await renameFile(id: fileId, newName: newName, token: token)
    }

    private func renameFile(id: String, newName: String, token: String) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?supportsAllDrives=true")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": newName])

        let (data, response) = try await GoogleDriveAuthService.performResilientDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errText = String(data: data, encoding: .utf8) ?? "Rename failed"
            throw NSError(domain: "GoogleDrive", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: errText])
        }
    }

    func readFileRange(fileId: String, accountID: String?, offset: UInt64, length: Int) async throws -> Data {
        if length > 0, let fullCached = recentRangeCache.cachedExactSlice(fileId: fileId, offset: offset, length: UInt64(length)) {
            return fullCached
        }
        let token = try await authService.getValidAccessToken(for: accountID)
        let end = offset + UInt64(max(0, length - 1))
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")

        let (data, response) = try await GoogleDriveAuthService.performResilientDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errText = String(data: data, encoding: .utf8) ?? "Range read failed"
            throw NSError(domain: "GoogleDrive", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: errText])
        }
        if httpResponse.statusCode == 206 && data.count <= 512 * 1024 {
            recentRangeCache.store(fileId: fileId, offset: offset, data: data)
        }
        return data
    }

    func fetchFileSize(fileId: String, accountID: String?) async throws -> Int64 {
        let token = try await authService.getValidAccessToken(for: accountID)
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
        components.queryItems = [
            URLQueryItem(name: "fields", value: "size"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        guard let url = components.url else {
            throw NSError(domain: "GoogleDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid file metadata URL"])
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await GoogleDriveAuthService.performResilientDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "GoogleDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to read file size from Google Drive."])
        }
        if let szStr = json["size"] as? String, let sz = Int64(szStr) {
            return sz
        }
        if let szNum = json["size"] as? NSNumber {
            return szNum.int64Value
        }
        return 0
    }

    func makeStreamingAsset(
        fileId: String,
        filename: String,
        knownFileSize: Int64?,
        accountID: String?
    ) async throws -> RemoteVideoStreamHandle {
        let resolvedSize: Int64
        if let knownFileSize, knownFileSize > 0 {
            resolvedSize = knownFileSize
        } else {
            resolvedSize = try await fetchFileSize(fileId: fileId, accountID: accountID)
        }
        guard resolvedSize > 0 else {
            throw NSError(domain: "GoogleDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "Remote video file is empty."])
        }
        return try RemoteVideoStreamHandle.makeStreaming(
            filename: filename,
            fileSize: UInt64(resolvedSize)
        ) { [weak self] offset, length, onData in
            guard let self else { throw CancellationError() }
            try await self.streamFileRange(
                fileId: fileId,
                accountID: accountID,
                offset: offset,
                length: length,
                onData: onData
            )
        }
    }

    private func streamFileRange(
        fileId: String,
        accountID: String?,
        offset: UInt64,
        length: UInt64,
        onData: @escaping @Sendable (Data) -> Void
    ) async throws {
        guard length > 0 else { return }

        // For short metadata/seek requests (<= 512 KB), coalesce any cached slices + network bytes
        // into a single onData delivery so AVAssetResourceLoader does not drop trailing packets.
        if length <= 512 * 1024 {
            let combined = try await loadCoalescedSmallRange(
                fileId: fileId,
                accountID: accountID,
                offset: offset,
                length: length
            )
            if !combined.isEmpty {
                onData(combined)
            }
            return
        }

        var cursor = offset
        let endOffset = offset + length

        while cursor < endOffset {
            if Task.isCancelled {
                throw CancellationError()
            }
            if let cached = recentRangeCache.cachedPrefixSlice(fileId: fileId, offset: cursor, maxLength: endOffset - cursor) {
                let wasZeroOffset = (cursor == 0)
                onData(cached)
                cursor += UInt64(cached.count)
                if wasZeroOffset {
                    // Brief yield so AVAssetResourceLoader can cancel req#2 when seeking to trailing moov.
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                continue
            }
            // Keep the initial offset-0 header probe bounded to 512 KB so AVPlayer can inspect
            // ftyp/mdat and cancel to seek to a trailing moov atom instead of streaming the full file.
            let targetWindow: UInt64 = (cursor == 0) ? (512 * 1024) : (8 * 1024 * 1024)
            let windowLen = min(targetWindow, endOffset - cursor)
            let delivered: UInt64
            do {
                delivered = try await performSingleRangeStream(
                    fileId: fileId,
                    accountID: accountID,
                    offset: cursor,
                    length: windowLen,
                    forceRefreshToken: false,
                    onData: onData
                )
            } catch let nsErr as NSError where nsErr.domain == "GoogleDrive" && nsErr.code == 401 {
                delivered = try await performSingleRangeStream(
                    fileId: fileId,
                    accountID: accountID,
                    offset: cursor,
                    length: windowLen,
                    forceRefreshToken: true,
                    onData: onData
                )
            }
            if delivered == 0 {
                break
            }
            cursor += delivered
        }
    }

    private func loadCoalescedSmallRange(
        fileId: String,
        accountID: String?,
        offset: UInt64,
        length: UInt64
    ) async throws -> Data {
        if let exact = recentRangeCache.cachedExactSlice(fileId: fileId, offset: offset, length: length) {
            return exact
        }
        let endOffset = offset + length
        let suffixCache = recentRangeCache.cachedCoveringEnd(fileId: fileId, rangeStart: offset, rangeEnd: endOffset)
        let fetchEnd = suffixCache?.offset ?? endOffset
        var result = Data()
        result.reserveCapacity(Int(length))

        var cursor = offset
        while cursor < fetchEnd {
            if Task.isCancelled {
                throw CancellationError()
            }
            if let cachedPrefix = recentRangeCache.cachedPrefixSlice(fileId: fileId, offset: cursor, maxLength: fetchEnd - cursor) {
                result.append(cachedPrefix)
                cursor += UInt64(cachedPrefix.count)
                continue
            }
            let chunkLen = fetchEnd - cursor
            let fetched = try await readFileRange(
                fileId: fileId,
                accountID: accountID,
                offset: cursor,
                length: Int(chunkLen)
            )
            if fetched.isEmpty {
                break
            }
            result.append(fetched)
            cursor += UInt64(fetched.count)
        }
        if let suffixCache, cursor == suffixCache.offset {
            let needed = Int(endOffset - suffixCache.offset)
            result.append(suffixCache.data.prefix(needed))
        }
        if result.count <= 512 * 1024 && !result.isEmpty {
            recentRangeCache.store(fileId: fileId, offset: offset, data: result)
        }
        return result
    }

    private func performSingleRangeStream(
        fileId: String,
        accountID: String?,
        offset: UInt64,
        length: UInt64,
        forceRefreshToken: Bool,
        onData: @escaping @Sendable (Data) -> Void
    ) async throws -> UInt64 {
        let token = try await authService.getValidAccessToken(for: accountID, forceRefresh: forceRefreshToken)
        let end = offset + length - 1
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let session = streamingSession
        let task = session.dataTask(with: request)
        let entry = GoogleDriveRangeStreamEntry(
            expectedOffset: offset,
            expectedLength: length,
            onData: onData
        )
        rangeStreamDelegate.register(entry: entry, for: task.taskIdentifier)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if entry.attachContinuationAndShouldCancel(continuation) {
                    rangeStreamDelegate.remove(taskIdentifier: task.taskIdentifier)
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
            let removed = rangeStreamDelegate.remove(taskIdentifier: task.taskIdentifier)
            if let cont = (removed ?? entry).cancelAndTakeContinuation() {
                cont.resume(throwing: CancellationError())
            }
        }
    }

    func downloadFile(
        fileId: String,
        accountID: String?,
        to localURL: URL,
        expectedFileSize: Int64? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let token = try await authService.getValidAccessToken(for: accountID)
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let delegate = progressHandler.map {
            DownloadProgressDelegate(expectedBytes: expectedFileSize ?? 0, onProgress: $0)
        }
        let (tempURL, response) = try await uploadSession.download(for: request, delegate: delegate)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "GoogleDrive", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Failed to download file from Google Drive"])
        }
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: localURL)
    }

    func fetchThumbnailLink(fileId: String, accountID: String?) async -> String? {
        guard let token = try? await authService.getValidAccessToken(for: accountID),
              let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?fields=thumbnailLink&supportsAllDrives=true") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await GoogleDriveAuthService.performResilientDataRequest(request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["thumbnailLink"] as? String
    }

    func fetchThumbnailData(thumbnailLink: String, accountID: String?) async throws -> Data {
        let token = try await authService.getValidAccessToken(for: accountID)
        guard let url = URL(string: thumbnailLink) else {
            throw NSError(domain: "GoogleDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid thumbnail URL"])
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await GoogleDriveAuthService.performResilientDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "GoogleDrive", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Thumbnail fetch failed"])
        }
        return data
    }

    /// Updates an existing Google Drive file in place via atomic resumable `PATCH`.
    /// Google Drive stages uploaded chunks under the session URI and commits atomically on
    /// the final byte, preserving the existing file ID and leaving the original intact if cancelled.
    func updateFileContent(
        fileId: String,
        localURL: URL,
        filename: String,
        photoDate: Date?,
        accountID: String?,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let token = try await authService.getValidAccessToken(for: accountID)
        let mime = mimeType(for: filename)

        try await uploadPreparedFile(
            fileURL: localURL,
            filename: filename,
            to: "",
            mimeTypeOverride: mime,
            photoDate: photoDate,
            updatingFileId: fileId,
            token: token,
            progressHandler: progressHandler
        )
        recentRangeCache.removeAll(forFileId: fileId)
    }

    // MARK: - Upload

    /// Upload a single prepared local file to Google Drive via resumable upload protocol (`POST` create or `PATCH` in-place update)
    /// Direct streaming avoids timeout on large files and slow networks without multipart file overhead
    @discardableResult
    private func uploadPreparedFile(
        fileURL: URL,
        filename: String,
        to folderId: String,
        parentIDsOverride: [String]? = nil,
        mimeTypeOverride: String? = nil,
        photoDate: Date?,
        updatingFileId: String? = nil,
        token: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let mime = mimeTypeOverride ?? mimeType(for: filename)
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (fileAttributes?[.size] as? Int64) ?? 0

        let isUpdate = updatingFileId != nil
        var metadata: [String: Any] = [:]
        if !isUpdate {
            metadata["name"] = filename
            let effectiveParents = parentIDsOverride ?? [folderId]
            if !effectiveParents.isEmpty {
                metadata["parents"] = effectiveParents
            }
        }

        if let photoDate = photoDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let dateString = formatter.string(from: photoDate)
            if !isUpdate {
                metadata["createdTime"] = dateString
            }
            metadata["modifiedTime"] = dateString
        }

        let metadataData = try JSONSerialization.data(withJSONObject: metadata)

        // Resumable upload Step 1: Initiate session (`PATCH` updates in place atomically; `POST` creates)
        let initURLString = if let fileId = updatingFileId {
            "https://www.googleapis.com/upload/drive/v3/files/\(fileId)?uploadType=resumable&supportsAllDrives=true"
        } else {
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true"
        }
        var initRequest = URLRequest(url: URL(string: initURLString)!)
        initRequest.httpMethod = isUpdate ? "PATCH" : "POST"
        initRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        initRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initRequest.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
        if fileSize > 0 {
            initRequest.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
        }
        initRequest.httpBody = metadataData

        let (initData, initResponse) = try await uploadSession.data(for: initRequest)
        guard let httpInit = initResponse as? HTTPURLResponse, (200...299).contains(httpInit.statusCode),
              let uploadURIString = httpInit.value(forHTTPHeaderField: "Location"),
              let uploadURI = URL(string: uploadURIString) else {
            let err = String(data: initData, encoding: .utf8) ?? "Failed to initiate resumable upload"
            throw NSError(domain: "GoogleDrive", code: -5, userInfo: [NSLocalizedDescriptionKey: "Resumable init failed: \(err)"])
        }

        // Resumable upload Step 2: Stream file directly without multipart overhead
        var uploadRequest = URLRequest(url: uploadURI)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue(mime, forHTTPHeaderField: "Content-Type")
        if fileSize > 0 {
            uploadRequest.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        }

        let delegate = progressHandler.map { UploadProgressDelegate(onProgress: $0) }
        do {
            let (data, response) = try await uploadSession.upload(for: uploadRequest, fromFile: fileURL, delegate: delegate)
            guard let httpResponse = response as? HTTPURLResponse, (200...201).contains(httpResponse.statusCode) else {
                let errorText = String(data: data, encoding: .utf8) ?? "Upload failed"
                throw NSError(domain: "GoogleDrive", code: -6, userInfo: [NSLocalizedDescriptionKey: "Upload failed: \(errorText)"])
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let createdId = json["id"] as? String {
                return createdId
            }
            return ""
        } catch {
            if ExportBatchRunner.isCancellationError(error) || Task.isCancelled {
                let session = uploadSession
                Task.detached(priority: .utility) {
                    var cancelRequest = URLRequest(url: uploadURI)
                    cancelRequest.httpMethod = "DELETE"
                    _ = try? await session.data(for: cancelRequest)
                }
            }
            throw error
        }
    }

    // MARK: - Batch Export Workflow

    /// Export photo items to a target Google Drive folder with EXIF metadata embedding and conflict resolution
    func exportPhotos(
        items: [PhotoItem],
        to folderId: String,
        folderName: String,
        conflictResolution: ExportConflictResolution = .overwrite,
        accountID: String? = nil,
        sourceMediaSource: MediaSource = .photoLibrary,
        totalBatchCount: Int? = nil,
        initialSuccessfulItems: [PhotoItem] = [],
        progressHandler: @escaping (ExportProgress) -> Void
    ) async -> ExportProgress {
        var token: String
        do {
            token = try await authService.getValidAccessToken(for: accountID)
        } catch {
            return ExportBatchRunner.earlyFailureProgress(
                items: items,
                totalBatchCount: totalBatchCount,
                initialSuccessfulItems: initialSuccessfulItems,
                errorMessage: "Authentication error: \(error.localizedDescription)",
                progressHandler: progressHandler
            )
        }

        clearSubfolderCache()

        var itemsToProcess = items.sortedChronologicallyAscending()
        if conflictResolution == .skip {
            let conflicts = (try? await checkConflicts(for: itemsToProcess, in: folderId)) ?? []
            let conflictSet = Set(conflicts)
            itemsToProcess = itemsToProcess.filter { !conflictSet.contains($0.filename) }
        }

        let fileManager = FileManager.default
        return await ExportBatchRunner.runRemoteBatch(
            serviceName: "GoogleDriveExport",
            items: itemsToProcess,
            totalBatchCount: totalBatchCount ?? itemsToProcess.count,
            initialSuccessfulItems: initialSuccessfulItems,
            progressHandler: progressHandler,
            onAttemptError: { error, _, _, _ in
                if ExportBatchRunner.isUnauthorizedError(error),
                   let refreshed = try? await self.authService.getValidAccessToken(for: accountID, forceRefresh: true) {
                    token = refreshed
                    return true
                }
                return false
            },
            exportItem: { item, itemProgress in
                let targetFilename = item.filename

                // Determine target folder ID (resolving subfolder hierarchy if configured)
                var itemFolderId = folderId
                if !item.subfolderPath.isEmpty {
                    if let subId = try await findOrCreateSubfolderHierarchy(
                        path: item.subfolderPath,
                        under: folderId,
                        accountID: accountID,
                        accessToken: token,
                        createIfMissing: true
                    ) {
                        itemFolderId = subId
                    }
                }

                // Always override existing or partial files in the destination;
                // renaming happens only pre-export in ExportSummarySheet.
                let existingIDs = try await fetchExistingFileIDs(named: targetFilename, in: itemFolderId, token: token)
                for id in existingIDs {
                    try await deleteFile(id: id, token: token)
                }

                let preparedURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + targetFilename)
                defer {
                    try? fileManager.removeItem(at: preparedURL)
                }

                try await ExportBatchRunner.prepareMediaFile(
                    for: item,
                    destinationURL: preparedURL,
                    libraryService: libraryService,
                    exifService: exifService,
                    sourceMediaSource: sourceMediaSource,
                    progressHandler: { prepFraction in
                        itemProgress(prepFraction * 0.15)
                    }
                )

                let photoDate = item.creationDate ?? item.embeddedDate ?? item.asset?.creationDate
                try await uploadPreparedFile(
                    fileURL: preparedURL,
                    filename: targetFilename,
                    to: itemFolderId,
                    photoDate: photoDate,
                    token: token,
                    progressHandler: { uploadFraction in
                        itemProgress(0.15 + uploadFraction * 0.85)
                    }
                )
            }
        )
    }

    // MARK: - Helpers

    private func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        case "m4v": return "video/x-m4v"
        default: return "application/octet-stream"
        }
    }
}

private final class GoogleDriveRangeStreamEntry: @unchecked Sendable {
    let expectedOffset: UInt64
    let expectedLength: UInt64
    private let onData: @Sendable (Data) -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<UInt64, Error>?
    private var isCancelled = false
    private var isFinished = false
    private var statusCode: Int = 0
    private var isResponseAccepted = false
    private var deliveredBytes: UInt64 = 0
    private var errorData = Data()

    init(
        expectedOffset: UInt64,
        expectedLength: UInt64,
        onData: @escaping @Sendable (Data) -> Void
    ) {
        self.expectedOffset = expectedOffset
        self.expectedLength = expectedLength
        self.onData = onData
    }

    func attachContinuationAndShouldCancel(_ cont: CheckedContinuation<UInt64, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled || isFinished {
            isFinished = true
            return true
        }
        continuation = cont
        return false
    }

    func cancelAndTakeContinuation() -> CheckedContinuation<UInt64, Error>? {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        guard !isFinished else { return nil }
        isFinished = true
        let cont = continuation
        continuation = nil
        return cont
    }

    func handleResponse(_ response: URLResponse, task: URLSessionDataTask) -> Bool {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        lock.lock()
        statusCode = status
        let valid = (status == 206) || (status == 200 && expectedOffset == 0)
        isResponseAccepted = valid
        lock.unlock()

        if !valid {
            task.cancel()
            if let cont = finishTakingContinuation() {
                let err = NSError(
                    domain: "GoogleDrive",
                    code: status,
                    userInfo: [NSLocalizedDescriptionKey: "Range stream failed with HTTP \(status)"]
                )
                cont.resume(throwing: err)
            }
            return false
        }
        return true
    }

    func handleData(_ data: Data, task: URLSessionDataTask) {
        let emitChunk: Data?
        let shouldFinishFull200: Bool
        lock.lock()
        if isCancelled || isFinished {
            lock.unlock()
            return
        }
        if !isResponseAccepted {
            if errorData.count < 2048 {
                errorData.append(data.prefix(2048 - errorData.count))
            }
            lock.unlock()
            return
        }
        let remaining = expectedLength > deliveredBytes ? expectedLength - deliveredBytes : 0
        if remaining == 0 {
            emitChunk = nil
            shouldFinishFull200 = true
        } else if UInt64(data.count) > remaining {
            emitChunk = data.prefix(Int(remaining))
            deliveredBytes += remaining
            shouldFinishFull200 = (statusCode == 200)
        } else {
            emitChunk = data
            deliveredBytes += UInt64(data.count)
            shouldFinishFull200 = (statusCode == 200 && deliveredBytes >= expectedLength)
        }
        lock.unlock()

        if let emitChunk, !emitChunk.isEmpty {
            onData(emitChunk)
        }
        if shouldFinishFull200 {
            task.cancel()
            complete(error: nil)
        }
    }

    func complete(error: Error?) {
        guard let cont = finishTakingContinuation() else { return }
        lock.lock()
        let status = statusCode
        let delivered = deliveredBytes
        let errText = errorData.isEmpty ? nil : String(data: errorData, encoding: .utf8)
        lock.unlock()

        if let error {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                cont.resume(throwing: CancellationError())
            } else {
                cont.resume(throwing: error)
            }
            return
        }

        if status > 0 && !(200...299).contains(status) {
            let err = NSError(
                domain: "GoogleDrive",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: errText ?? "Range stream failed (HTTP \(status))"]
            )
            cont.resume(throwing: err)
            return
        }

        cont.resume(returning: delivered)
    }

    private func finishTakingContinuation() -> CheckedContinuation<UInt64, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return nil }
        isFinished = true
        let cont = continuation
        continuation = nil
        return cont
    }
}

private final class GoogleDriveRangeStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int: GoogleDriveRangeStreamEntry] = [:]

    func register(entry: GoogleDriveRangeStreamEntry, for taskIdentifier: Int) {
        lock.lock()
        entries[taskIdentifier] = entry
        lock.unlock()
    }

    @discardableResult
    func remove(taskIdentifier: Int) -> GoogleDriveRangeStreamEntry? {
        lock.lock()
        let entry = entries.removeValue(forKey: taskIdentifier)
        lock.unlock()
        return entry
    }

    private func entry(for taskIdentifier: Int) -> GoogleDriveRangeStreamEntry? {
        lock.lock()
        let entry = entries[taskIdentifier]
        lock.unlock()
        return entry
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let entry = entry(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        let accepted = entry.handleResponse(response, task: dataTask)
        if !accepted {
            remove(taskIdentifier: dataTask.taskIdentifier)
        }
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        entry(for: dataTask.taskIdentifier)?.handleData(data, task: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        remove(taskIdentifier: task.taskIdentifier)?.complete(error: error)
    }
}

private final class GoogleDriveRangeCache: @unchecked Sendable {
    private struct Entry {
        let offset: UInt64
        let data: Data
        let storedAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var entriesByFile: [String: [Entry]] = [:]
    private var fileOrder: [String] = []
    private let maxFiles = 8
    private let maxTotalBytes = 4 * 1024 * 1024
    private let ttl: Duration = .seconds(120)

    func store(fileId: String, offset: UInt64, data: Data) {
        guard !data.isEmpty, data.count <= 512 * 1024 else { return }
        let now = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now)
        var list = entriesByFile[fileId] ?? []
        let end = offset + UInt64(data.count)
        list.removeAll { existing in
            let existingEnd = existing.offset + UInt64(existing.data.count)
            return offset <= existing.offset && end >= existingEnd
        }
        list.append(Entry(offset: offset, data: data, storedAt: now))
        entriesByFile[fileId] = list
        fileOrder.removeAll { $0 == fileId }
        fileOrder.append(fileId)
        enforceLimitsLocked()
    }

    func removeAll(forFileId fileId: String) {
        lock.lock()
        entriesByFile.removeValue(forKey: fileId)
        fileOrder.removeAll { $0 == fileId }
        lock.unlock()
    }

    func cachedExactSlice(fileId: String, offset: UInt64, length: UInt64) -> Data? {
        guard length > 0 else { return Data() }
        let now = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now)
        guard let list = entriesByFile[fileId] else { return nil }
        let end = offset + length
        for entry in list {
            let entryEnd = entry.offset + UInt64(entry.data.count)
            if offset >= entry.offset && end <= entryEnd {
                let relStart = Int(offset - entry.offset)
                return entry.data.subdata(in: relStart..<(relStart + Int(length)))
            }
        }
        return nil
    }

    func cachedPrefixSlice(fileId: String, offset: UInt64, maxLength: UInt64) -> Data? {
        guard maxLength > 0 else { return nil }
        let now = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now)
        guard let list = entriesByFile[fileId] else { return nil }
        var best: Data? = nil
        for entry in list {
            let entryEnd = entry.offset + UInt64(entry.data.count)
            if offset >= entry.offset && offset < entryEnd {
                let relStart = Int(offset - entry.offset)
                let available = Int(min(maxLength, entryEnd - offset))
                if best == nil || available > best!.count {
                    best = entry.data.subdata(in: relStart..<(relStart + available))
                }
            }
        }
        return best
    }

    func cachedCoveringEnd(fileId: String, rangeStart: UInt64, rangeEnd: UInt64) -> (offset: UInt64, data: Data)? {
        let now = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now)
        guard let list = entriesByFile[fileId] else { return nil }
        var best: Entry? = nil
        for entry in list {
            let entryEnd = entry.offset + UInt64(entry.data.count)
            if entry.offset > rangeStart && entry.offset < rangeEnd && entryEnd >= rangeEnd {
                if best == nil || entry.offset < best!.offset {
                    best = entry
                }
            }
        }
        return best.map { ($0.offset, $0.data) }
    }

    private func pruneExpiredLocked(now: ContinuousClock.Instant) {
        for (fid, list) in entriesByFile {
            let kept = list.filter { $0.storedAt.duration(to: now) < ttl }
            if kept.isEmpty {
                entriesByFile.removeValue(forKey: fid)
                fileOrder.removeAll { $0 == fid }
            } else if kept.count != list.count {
                entriesByFile[fid] = kept
            }
        }
    }

    private func enforceLimitsLocked() {
        while fileOrder.count > maxFiles {
            let evicted = fileOrder.removeFirst()
            entriesByFile.removeValue(forKey: evicted)
        }
        var total = entriesByFile.values.reduce(0) { sum, list in
            sum + list.reduce(0) { $0 + $1.data.count }
        }
        while total > maxTotalBytes && !fileOrder.isEmpty {
            let evicted = fileOrder.removeFirst()
            let removed = entriesByFile.removeValue(forKey: evicted) ?? []
            total -= removed.reduce(0) { $0 + $1.data.count }
        }
    }
}

