//
//  GooglePhotosService.swift
//  Photo Exporter
//

import Foundation
import Photos
import UIKit

/// Service managing Google Photos Library API interactions and media uploads
final class GooglePhotosService {
    static let shared = GooglePhotosService()

    private let authService = GooglePhotosAuthService.shared
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

    private init() {}

    // MARK: - Export Media to Google Photos

    /// Uploads an array of PhotoItem objects directly to Google Photos library
    func exportPhotos(
        items: [PhotoItem],
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

        let fileManager = FileManager.default
        return await ExportBatchRunner.runRemoteBatch(
            serviceName: "GooglePhotosExport",
            items: items,
            totalBatchCount: totalBatchCount,
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
                token = try await self.authService.getValidAccessToken(for: accountID)
                let targetFilename = item.filename
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

                let uploadToken = try await uploadRawMediaBytes(
                    fileURL: preparedURL,
                    filename: targetFilename,
                    isVideo: item.isVideo,
                    token: token,
                    progressHandler: { uploadFraction in
                        itemProgress(0.15 + uploadFraction * 0.80)
                    }
                )

                try await createMediaItem(
                    uploadToken: uploadToken,
                    filename: targetFilename,
                    token: token
                )
            }
        )
    }

    // MARK: - API Calls

    /// Uploads raw media file bytes to Google Photos uploads endpoint and returns the uploadToken
    private func uploadRawMediaBytes(
        fileURL: URL,
        filename: String,
        isVideo: Bool,
        token: String,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        guard let uploadURL = URL(string: "https://photoslibrary.googleapis.com/v1/uploads") else {
            throw NSError(domain: "GooglePhotos", code: -11, userInfo: [NSLocalizedDescriptionKey: "Invalid uploads endpoint URL"])
        }

        let contentType = mimeType(for: filename, isVideo: isVideo)

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(contentType, forHTTPHeaderField: "X-Goog-Upload-Content-Type")
        request.setValue("raw", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue(filename, forHTTPHeaderField: "X-Goog-Upload-File-Name")

        let delegate = progressHandler.map { UploadProgressDelegate(onProgress: $0) }
        let (data, response) = try await uploadSession.upload(for: request, fromFile: fileURL, delegate: delegate)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            throw NSError(domain: "GooglePhotos", code: -12, userInfo: [NSLocalizedDescriptionKey: "Upload failed: \(errorText)"])
        }

        guard let uploadToken = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !uploadToken.isEmpty else {
            throw NSError(domain: "GooglePhotos", code: -13, userInfo: [NSLocalizedDescriptionKey: "Missing upload token in Google Photos response"])
        }

        return uploadToken
    }

    /// Registers an uploaded media item into the user's Google Photos library using mediaItems:batchCreate
    private func createMediaItem(
        uploadToken: String,
        filename: String,
        token: String
    ) async throws {
        guard let createURL = URL(string: "https://photoslibrary.googleapis.com/v1/mediaItems:batchCreate") else {
            throw NSError(domain: "GooglePhotos", code: -14, userInfo: [NSLocalizedDescriptionKey: "Invalid batchCreate URL"])
        }

        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "newMediaItems": [
                [
                    "simpleMediaItem": [
                        "fileName": filename,
                        "uploadToken": uploadToken
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await uploadSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            throw NSError(domain: "GooglePhotos", code: -15, userInfo: [NSLocalizedDescriptionKey: "Failed to create Google Photos media item: \(errorText)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["newMediaItemResults"] as? [[String: Any]],
              let firstResult = results.first else {
            throw NSError(domain: "GooglePhotos", code: -16, userInfo: [NSLocalizedDescriptionKey: "Invalid batchCreate response from Google Photos"])
        }

        if let status = firstResult["status"] as? [String: Any] {
            let code = (status["code"] as? Int) ?? 0
            let message = (status["message"] as? String) ?? ""
            if code != 0 || (!message.isEmpty && message.lowercased() != "success") {
                let displayMsg = message.isEmpty ? "Google Photos rejected item creation (code \(code))" : message
                throw NSError(domain: "GooglePhotos", code: code != 0 ? code : -17, userInfo: [NSLocalizedDescriptionKey: displayMsg])
            }
        }
    }

    // MARK: - Helpers

    private func mimeType(for filename: String, isVideo: Bool) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if isVideo {
            switch ext {
            case "mov": return "video/quicktime"
            case "mp4": return "video/mp4"
            case "m4v": return "video/x-m4v"
            case "avi": return "video/x-msvideo"
            case "wmv": return "video/x-ms-wmv"
            default: return "video/mp4"
            }
        } else {
            switch ext {
            case "jpg", "jpeg": return "image/jpeg"
            case "png": return "image/png"
            case "heic": return "image/heic"
            case "heif": return "image/heif"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            case "dng": return "image/x-adobe-dng"
            case "tiff", "tif": return "image/tiff"
            default: return "image/jpeg"
            }
        }
    }
}

