//
//  ExifMetadataService.swift
//  Photo Exporter
//

import Foundation
import Photos
import ImageIO
import CoreLocation
import AVFoundation
import CoreData
import UIKit
import CoreImage
import UniformTypeIdentifiers
import zlib

/// Service for reading and writing EXIF/TIFF metadata using ImageIO
final class ExifMetadataService {
    static let shared = ExifMetadataService()

    private init() {}

    // MARK: - Video Metadata Parsing

    /// Read comprehensive metadata from a video file URL and asset
    func parseVideoMetadata(
        from fileURL: URL,
        asset: PHAsset,
        filename: String,
        editedMetrics: PhotoLibraryService.EditedVideoMetrics? = nil
    ) async -> PhotoExifMetadata {
        let avAsset = AVURLAsset(url: fileURL)
        let rawByteCount = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let byteCount = (editedMetrics?.estimatedFileSize ?? 0) > 0 ? (editedMetrics?.estimatedFileSize ?? rawByteCount) : rawByteCount
        let ext = fileURL.pathExtension.uppercased()

        var embeddedCreationDateStr: String? = nil
        var embeddedLocationStr: String? = nil
        var make: String? = nil
        var model: String? = nil
        var lensModel: String? = nil

        let items = avAsset.metadata
        for item in items {
            let keyStr = (item.key as? String) ?? ""
            let valStr = item.stringValue

            if keyStr == AVMetadataKey.quickTimeMetadataKeyCreationDate.rawValue ||
               keyStr == "com.apple.quicktime.creationdate" ||
               item.commonKey == .commonKeyCreationDate {
                embeddedCreationDateStr = valStr
            } else if keyStr == AVMetadataKey.quickTimeMetadataKeyLocationISO6709.rawValue ||
                      keyStr == "com.apple.quicktime.location.ISO6709" ||
                      item.commonKey == .commonKeyLocation {
                embeddedLocationStr = valStr
            } else if keyStr == AVMetadataKey.quickTimeMetadataKeyMake.rawValue ||
                      keyStr == "com.apple.quicktime.make" ||
                      item.commonKey == .commonKeyMake {
                make = valStr
            } else if keyStr == AVMetadataKey.quickTimeMetadataKeyModel.rawValue ||
                      keyStr == "com.apple.quicktime.model" ||
                      item.commonKey == .commonKeyModel {
                model = valStr
            } else if keyStr.contains("lens_model") {
                lensModel = valStr
            }
        }

        // Extended attributes fallback from Photos app
        let extInfo = asset.photosAppExtendedAttributesInfo
        if make == nil { make = extInfo.cameraMake }
        if model == nil { model = extInfo.cameraModel }
        if lensModel == nil { lensModel = extInfo.lensModel }

        // Timezone parsing
        var videoExifTimeZone: TimeZone? = nil
        if let creationStr = embeddedCreationDateStr {
            if let tz = parseTimezone(fromOffset: String(creationStr.suffix(6))) {
                videoExifTimeZone = tz
            } else if let tz = parseTimezone(fromOffset: String(creationStr.suffix(5))) {
                videoExifTimeZone = tz
            }
        }
        let effectiveTimeZone = asset.photosAppTimeZone ?? videoExifTimeZone ?? .current
        let originalTimeZone: TimeZone = {
            if let vExifTZ = videoExifTimeZone {
                return vExifTZ
            }
            if asset.isPhotosAppTimeZoneAdjusted {
                return asset.photosAppOriginalTimeZone ?? .current
            } else {
                return asset.photosAppTimeZone ?? .current
            }
        }()

        // Embedded date
        var embeddedDate: Date? = embeddedCreationDateStr.flatMap { parseQuickTimeCreationDateString($0) }
        if embeddedDate == nil {
            embeddedDate = extInfo.originalDate
        }

        // Check if date was adjusted
        var isDateAdjusted = asset.isPhotosAppTimeZoneAdjusted
        if let origDate = extInfo.originalDate, let curDate = asset.creationDate {
            if abs(curDate.timeIntervalSince(origDate)) > 1.0 {
                isDateAdjusted = true
            }
        } else if let emb = embeddedDate, let curDate = asset.creationDate {
            if abs(curDate.timeIntervalSince(emb)) > 1.0 {
                isDateAdjusted = true
            }
        }

        // Original GPS Location
        let originalLocation: CLLocation? = {
            if let locStr = embeddedLocationStr, let parsed = parseISO6709(locStr) {
                return parsed
            }
            return extInfo.originalLocation
        }()

        let isGPSAdjusted: Bool
        if let curLoc = asset.location, let origLoc = originalLocation {
            isGPSAdjusted = curLoc.distance(from: origLoc) > 10.0
        } else if asset.location != nil && originalLocation == nil {
            isGPSAdjusted = true
        } else if asset.location == nil && originalLocation != nil {
            isGPSAdjusted = true
        } else {
            isGPSAdjusted = false
        }

        let effectiveLocation = isGPSAdjusted ? asset.location : (asset.location ?? originalLocation)

        // Video track properties
        let tracks = avAsset.tracks(withMediaType: .video)
        var width = asset.pixelWidth
        var height = asset.pixelHeight
        var fps: Double? = extInfo.fps
        var codec: String? = extInfo.codec

        if let videoTrack = tracks.first {
            let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
            let w = Int(abs(transformedSize.width))
            let h = Int(abs(transformedSize.height))
            if w > 0 && h > 0 {
                width = w
                height = h
            }
            if fps == nil {
                let rate = Double(videoTrack.nominalFrameRate)
                if rate > 0 { fps = rate }
            }
            if codec == nil {
                if let desc = videoTrack.formatDescriptions as? [CMFormatDescription], let fd = desc.first {
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(fd)
                    let fourCC = withUnsafeBytes(of: mediaSubType.bigEndian) { String(bytes: $0, encoding: .ascii) }
                    codec = fourCC?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        let rawDuration = extInfo.duration ?? (asset.duration > 0 ? asset.duration : CMTimeGetSeconds(avAsset.duration))
        let duration = editedMetrics?.duration ?? rawDuration
        if let ew = editedMetrics?.pixelWidth, let eh = editedMetrics?.pixelHeight, ew > 0, eh > 0 {
            width = ew
            height = eh
        }

        let isSavedFromOtherApps = checkIfSavedFromOtherApps(
            asset: asset,
            make: make,
            model: model,
            filename: filename,
            exifDict: nil
        )

        let effectiveOffsetString = DateFormatters.exifTimezoneOffset(for: asset.creationDate ?? Date(), in: effectiveTimeZone)
        let hasEmbeddedTimeZone = (videoExifTimeZone != nil)
        let rawDateAndGPSFields = extractVideoRawDateAndGPSFields(
            fileURL: fileURL,
            creationDateStr: embeddedCreationDateStr,
            locationISO6709Str: embeddedLocationStr
        )

        let hasEmbeddedCreationDate = (embeddedCreationDateStr != nil)
        let isDrifted = hasEmbeddedCreationDate
            ? isVideoMvhdDrifted(fileURL: fileURL, creationDate: asset.creationDate ?? embeddedDate)
            : false

        return PhotoExifMetadata(
            filename: filename,
            fileSizeString: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file),
            fileByteCount: byteCount,
            fileTypeString: ext.isEmpty ? "VIDEO" : ext,
            pixelWidth: width,
            pixelHeight: height,
            creationDate: asset.creationDate,
            embeddedDate: embeddedDate,
            isDateAdjusted: isDateAdjusted,
            isEdited: asset.hasAdjustments,
            timeZone: effectiveTimeZone,
            originalTimeZone: originalTimeZone,
            offsetTimeString: effectiveOffsetString,
            cameraMake: make,
            cameraModel: model,
            lensModel: lensModel,
            focalLength: nil,
            focalLength35mm: nil,
            aperture: nil,
            shutterSpeed: nil,
            iso: nil,
            exposureBias: nil,
            flashFired: nil,
            colorSpace: nil,
            isSavedFromOtherApps: isSavedFromOtherApps,
            appOriginHint: isSavedFromOtherApps ? identifyAppOrigin(filename: filename, make: make, model: model) : nil,
            location: effectiveLocation,
            originalLocation: originalLocation,
            isGPSAdjusted: isGPSAdjusted,
            altitude: effectiveLocation?.altitude,
            heading: effectiveLocation?.course,
            speed: effectiveLocation?.speed,
            isVideo: true,
            duration: duration,
            fps: fps,
            codec: codec,
            hasEmbeddedTimeZone: hasEmbeddedTimeZone,
            isDrifted: isDrifted,
            rawDateAndGPSFields: rawDateAndGPSFields
        )
    }

    /// Fast metadata evaluation for video asset in list
    nonisolated func evaluateVideoMetadataQuick(
        asset: PHAsset,
        filename: String,
        fileURL: URL? = nil
    ) -> (embeddedDate: Date?, isDateAdjusted: Bool, isGPSAdjusted: Bool, isFromOtherApps: Bool, hasEmbeddedTimeZone: Bool, timeZone: TimeZone, isDrifted: Bool) {
        let extInfo = asset.photosAppExtendedAttributesInfo

        var isDateAdjusted = asset.isPhotosAppTimeZoneAdjusted
        if let origDate = extInfo.originalDate, let curDate = asset.creationDate {
            if abs(curDate.timeIntervalSince(origDate)) > 1.0 {
                isDateAdjusted = true
            }
        }

        let isGPSAdjusted: Bool
        if let curLoc = asset.location, let origLoc = extInfo.originalLocation {
            isGPSAdjusted = curLoc.distance(from: origLoc) > 10.0
        } else if asset.location != nil && extInfo.originalLocation == nil {
            isGPSAdjusted = true
        } else if asset.location == nil && extInfo.originalLocation != nil {
            isGPSAdjusted = true
        } else {
            isGPSAdjusted = false
        }

        let isFromOtherApps = checkIfSavedFromOtherApps(
            asset: asset,
            make: extInfo.cameraMake,
            model: extInfo.cameraModel,
            filename: filename,
            exifDict: nil
        )

        let tzName = extInfo.originalTimeZoneName ?? ""
        let hasEmbeddedTimeZone = tzName.hasPrefix("GMT") || tzName.hasPrefix("UTC") || tzName.hasPrefix("+") || tzName.hasPrefix("-")
        let effectiveTimeZone = asset.photosAppTimeZone ?? .current
        let isDrifted: Bool
        if let fileURL = fileURL,
           let embeddedCreationDate = parseQuickTimeEmbeddedCreationDate(from: fileURL) {
            isDrifted = isVideoMvhdDrifted(fileURL: fileURL, creationDate: asset.creationDate ?? embeddedCreationDate)
        } else {
            isDrifted = false
        }

        return (extInfo.originalDate, isDateAdjusted, isGPSAdjusted, isFromOtherApps, hasEmbeddedTimeZone, effectiveTimeZone, isDrifted)
    }

    /// Embed adjusted date & time, timezone, and location into a video file using AVAssetExportSession passthrough
    func embedAdjustedVideoMetadata(
        sourceURL: URL,
        destinationURL: URL,
        targetDate: Date?,
        timeZone: TimeZone,
        adjustedLocation: CLLocation?,
        isGPSAdjusted: Bool,
        videoTakenDate: Date? = nil,
        fallbackLocation: CLLocation? = nil,
        clockwiseRotationSteps: Int = 0
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let steps = Self.clockwiseSteps(forDegrees: clockwiseRotationSteps * 90)
        let existingMetadata = asset.metadata

        var hasCreationDateItem = false
        var hasLocationItem = false
        var newMetadata = existingMetadata.filter { item in
            let keyStr = (item.key as? String) ?? ""
            let isCreationDateKey = keyStr == AVMetadataKey.quickTimeMetadataKeyCreationDate.rawValue ||
                                    keyStr == "com.apple.quicktime.creationdate" ||
                                    keyStr == AVMetadataKey.quickTimeUserDataKeyCreationDate.rawValue ||
                                    keyStr == "©day" ||
                                    keyStr == AVMetadataKey.isoUserDataKeyDate.rawValue ||
                                    keyStr == "date" ||
                                    keyStr.lowercased().contains("date") ||
                                    item.commonKey == .commonKeyCreationDate
            let isLocationKey = keyStr == AVMetadataKey.quickTimeMetadataKeyLocationISO6709.rawValue ||
                                keyStr == "com.apple.quicktime.location.ISO6709" ||
                                item.commonKey == .commonKeyLocation
            if targetDate != nil && isCreationDateKey {
                return false
            }
            if isGPSAdjusted && isLocationKey {
                return false
            }
            if isCreationDateKey {
                hasCreationDateItem = true
            }
            if isLocationKey {
                hasLocationItem = true
            }
            return true
        }

        // Add adjusted Date & Time / Timezone (or restore if stripped during edit render)
        if let newDate = targetDate ?? (!hasCreationDateItem ? videoTakenDate : nil) {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = timeZone
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            let dateStr = df.string(from: newDate)

            let dateItem = AVMutableMetadataItem()
            dateItem.keySpace = .quickTimeMetadata
            dateItem.key = AVMetadataKey.quickTimeMetadataKeyCreationDate as NSString
            dateItem.value = dateStr as NSString
            newMetadata.append(dateItem)
        }

        // Add adjusted GPS Location (or restore if stripped during edit render)
        if let loc = isGPSAdjusted ? adjustedLocation : (!hasLocationItem ? fallbackLocation : nil) {
            let isoStr = formatISO6709(location: loc)

            let locItem = AVMutableMetadataItem()
            locItem.keySpace = .quickTimeMetadata
            locItem.key = AVMetadataKey.quickTimeMetadataKeyLocationISO6709 as NSString
            locItem.value = isoStr as NSString
            newMetadata.append(locItem)
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try await Self.exportVideoAsset(
            asset,
            to: destinationURL,
            metadata: newMetadata,
            clockwiseSteps: steps
        )

        // AVAssetExportSession passthrough writes the current system date/time (Date.now) into
        // QuickTime container header boxes (mvhd CreateDate/ModifyDate, tkhd TrackCreateDate/TrackModifyDate,
        // and mdhd MediaCreateDate/MediaModifyDate).
        // Update these atoms in-place to the video taken date at UTC per ISO/IEC 14496-12 standard.
        let effectiveDate = targetDate ?? videoTakenDate ?? parseContainerCreationDate(from: sourceURL)
        if let effectiveDate = effectiveDate {
            try updateQuickTimeContainerDates(at: destinationURL, to: effectiveDate)
        }
    }

    // MARK: - Rotation Helpers (Images & Videos)

    private static let sharedCIContext = CIContext(options: nil)

    nonisolated static func normalizeRotationDegrees(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    nonisolated static func clockwiseSteps(forDegrees degrees: Int) -> Int {
        ((normalizeRotationDegrees(degrees) / 90) % 4 + 4) % 4
    }

    /// Computes next EXIF orientation after applying `clockwiseSteps` * 90° clockwise rotations.
    nonisolated static func rotateExifOrientation(_ orientation: Int, clockwiseSteps: Int) -> Int {
        let steps = ((clockwiseSteps % 4) + 4) % 4
        guard steps != 0 else { return orientation }
        let standardCycle = [1, 6, 3, 8]
        if let idx = standardCycle.firstIndex(of: orientation) {
            return standardCycle[(idx + steps) % 4]
        }
        let mirroredCycle = [2, 7, 4, 5]
        if let idx = mirroredCycle.firstIndex(of: orientation) {
            return mirroredCycle[(idx + steps) % 4]
        }
        return standardCycle[steps % 4]
    }

    /// Rotates a UIImage clockwise by `clockwiseSteps * 90°` for preview/thumbnail display.
    nonisolated static func rotateUIImage(_ image: UIImage, clockwiseSteps: Int) -> UIImage {
        let steps = ((clockwiseSteps % 4) + 4) % 4
        guard steps != 0 else { return image }

        let origSize = image.size
        guard origSize.width > 0 && origSize.height > 0 else { return image }

        let targetSize = (steps % 2 == 1)
            ? CGSize(width: origSize.height, height: origSize.width)
            : origSize

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.translateBy(x: targetSize.width / 2, y: targetSize.height / 2)
            cgCtx.rotate(by: CGFloat(steps) * (.pi / 2))
            image.draw(in: CGRect(
                x: -origSize.width / 2,
                y: -origSize.height / 2,
                width: origSize.width,
                height: origSize.height
            ))
        }
    }

    /// Renders physically rotated image data while preserving EXIF/TIFF/GPS metadata and resetting Orientation to 1.
    nonisolated static func rotateImageData(
        _ data: Data,
        targetType: CFString? = nil,
        clockwiseSteps: Int,
        overriddenProperties: [CFString: Any]? = nil
    ) throws -> Data {
        let steps = ((clockwiseSteps % 4) + 4) % 4
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw NSError(domain: "ExifMetadataService", code: -20, userInfo: [NSLocalizedDescriptionKey: "Failed to read image data for rotation"])
        }
        let detectedType = CGImageSourceGetType(source)
        let outType = targetType ?? detectedType ?? (UTType.jpeg.identifier as CFString)

        guard let inputCI = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw NSError(domain: "ExifMetadataService", code: -21, userInfo: [NSLocalizedDescriptionKey: "Failed to decode image for rotation"])
        }

        let outputCI: CIImage
        if steps == 0 {
            outputCI = inputCI
        } else {
            // CoreImage uses bottom-left Y-up coordinates, so negative angle rotates clockwise.
            let rotated = inputCI.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(steps) * (.pi / 2)))
            outputCI = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.origin.x, y: -rotated.extent.origin.y))
        }

        guard let cgImage = sharedCIContext.createCGImage(outputCI, from: outputCI.extent) else {
            throw NSError(domain: "ExifMetadataService", code: -22, userInfo: [NSLocalizedDescriptionKey: "Failed to render rotated image"])
        }

        var props = overriddenProperties ?? ((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:])
        props[kCGImagePropertyOrientation] = 1
        props.removeValue(forKey: kCGImagePropertyPixelWidth)
        props.removeValue(forKey: kCGImagePropertyPixelHeight)
        var tiffDict = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiffDict[kCGImagePropertyTIFFOrientation] = 1
        props[kCGImagePropertyTIFFDictionary] = tiffDict
        if outType == (UTType.jpeg.identifier as CFString) && props[kCGImageDestinationLossyCompressionQuality] == nil {
            props[kCGImageDestinationLossyCompressionQuality] = 0.95
        }

        let outData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outData as CFMutableData, outType, 1, nil) else {
            throw NSError(domain: "ExifMetadataService", code: -23, userInfo: [NSLocalizedDescriptionKey: "Failed to create rotated image destination"])
        }
        CGImageDestinationAddImage(destination, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ExifMetadataService", code: -24, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize rotated image"])
        }
        return outData as Data
    }

    /// Computes normalized display transform and render dimensions for rotating a video track clockwise by `clockwiseSteps * 90°`.
    nonisolated static func rotatedVideoTransform(
        for naturalSize: CGSize,
        existingTransform: CGAffineTransform,
        clockwiseSteps: Int
    ) -> (transform: CGAffineTransform, renderSize: CGSize) {
        let steps = ((clockwiseSteps % 4) + 4) % 4
        let rawTransform = steps == 0
            ? existingTransform
            : existingTransform.concatenating(CGAffineTransform(rotationAngle: CGFloat(steps) * (.pi / 2)))
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(rawTransform)
        let normalizedTransform = rawTransform.concatenating(
            CGAffineTransform(translationX: -transformedRect.origin.x, y: -transformedRect.origin.y)
        )
        let width = max(2, floor(abs(transformedRect.width)))
        let height = max(2, floor(abs(transformedRect.height)))
        return (normalizedTransform, CGSize(width: width, height: height))
    }

    /// Builds an AVVideoComposition that rotates an AVAsset's video track visually for playback or re-encoded export.
    func makeRotatedVideoComposition(for asset: AVAsset, clockwiseSteps: Int) async -> AVVideoComposition? {
        let steps = ((clockwiseSteps % 4) + 4) % 4
        guard steps != 0 else { return nil }
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        guard naturalSize.width > 0 && naturalSize.height > 0 else { return nil }
        let existingTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let nominalFPS = (try? await videoTrack.load(.nominalFrameRate)) ?? 30
        let duration = (try? await asset.load(.duration)) ?? CMTime(seconds: 600, preferredTimescale: 600)

        let (normalizedTransform, renderSize) = Self.rotatedVideoTransform(
            for: naturalSize,
            existingTransform: existingTransform,
            clockwiseSteps: steps
        )

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: Int32(max(1, round(nominalFPS > 0 ? nominalFPS : 30))))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration.isValid && duration > .zero ? duration : CMTime(seconds: 3600, preferredTimescale: 600))

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(normalizedTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]
        return composition
    }

    /// Exports an AVAsset to `destinationURL` with optional clockwise rotation and QuickTime metadata.
    /// Uses passthrough remuxing (`preferredTransform` matrix update) when possible and falls back to re-encoding with `AVMutableVideoComposition`.
    static func exportVideoAsset(
        _ asset: AVAsset,
        to destinationURL: URL,
        metadata: [AVMetadataItem]? = nil,
        clockwiseSteps: Int
    ) async throws {
        let steps = ((clockwiseSteps % 4) + 4) % 4
        try? FileManager.default.removeItem(at: destinationURL)

        let canTryPassthrough: Bool = {
            guard steps != 0 else { return true }
            return asset is AVURLAsset
        }()

        if canTryPassthrough {
            var exportAsset: AVAsset = asset
            if steps != 0 {
                let composition = AVMutableComposition()
                let tracks = (try? await asset.load(.tracks)) ?? []
                let assetDuration = (try? await asset.load(.duration)) ?? .zero
                for track in tracks {
                    let mediaType = track.mediaType
                    guard mediaType == .video || mediaType == .audio else { continue }
                    let timeRange = (try? await track.load(.timeRange)) ?? CMTimeRange(start: .zero, duration: assetDuration)
                    guard timeRange.duration.isValid && timeRange.duration > .zero else { continue }
                    if let compTrack = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try? compTrack.insertTimeRange(timeRange, of: track, at: .zero)
                        if mediaType == .video {
                            let natSize = (try? await track.load(.naturalSize)) ?? .zero
                            let origTransform = (try? await track.load(.preferredTransform)) ?? .identity
                            compTrack.preferredTransform = Self.rotatedVideoTransform(
                                for: natSize,
                                existingTransform: origTransform,
                                clockwiseSteps: steps
                            ).transform
                        }
                    }
                }
                if !composition.tracks(withMediaType: .video).isEmpty {
                    exportAsset = composition
                }
            }

            if let session = AVAssetExportSession(asset: exportAsset, presetName: AVAssetExportPresetPassthrough) {
                let supported = session.supportedFileTypes
                let fileType: AVFileType = supported.contains(.mov) ? .mov : (supported.first ?? .mov)
                session.outputURL = destinationURL
                session.outputFileType = fileType
                if let metadata {
                    session.metadata = metadata
                }
                await withCheckedContinuation { continuation in
                    session.exportAsynchronously {
                        continuation.resume()
                    }
                }
                if session.status == .completed {
                    return
                }
                try? FileManager.default.removeItem(at: destinationURL)
                if steps == 0 {
                    throw session.error ?? NSError(domain: "ExifMetadataService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video export failed with status \(session.status.rawValue)"])
                }
            } else if steps == 0 {
                throw NSError(domain: "ExifMetadataService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAssetExportSession for video"])
            }
        }

        // Re-encode fallback with AVVideoComposition when passthrough isn't applicable (e.g. AVComposition or unsupported codec container)
        let preset = AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NSError(domain: "ExifMetadataService", code: -25, userInfo: [NSLocalizedDescriptionKey: "Failed to create video export session"])
        }
        let supported = session.supportedFileTypes
        let fileType: AVFileType = supported.contains(.mov) ? .mov : (supported.first ?? .mov)
        session.outputURL = destinationURL
        session.outputFileType = fileType
        if let metadata {
            session.metadata = metadata
        }
        if steps != 0, let composition = await Self.shared.makeRotatedVideoComposition(for: asset, clockwiseSteps: steps) {
            session.videoComposition = composition
        }

        await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        if session.status != .completed {
            throw session.error ?? NSError(domain: "ExifMetadataService", code: -26, userInfo: [NSLocalizedDescriptionKey: "Video export failed with status \(session.status.rawValue)"])
        }
    }

    /// Update QuickTime container date tags (mvhd CreateDate/ModifyDate,
    /// tkhd TrackCreateDate/TrackModifyDate, mdhd MediaCreateDate/MediaModifyDate)
    /// to the target UTC timestamp directly in the file.
    private func updateQuickTimeContainerDates(at fileURL: URL, to targetDate: Date) throws {
        let fileHandle = try FileHandle(forUpdating: fileURL)
        defer {
            try? fileHandle.close()
        }

        let macEpochOffset: Int64 = 2_082_844_800 // Seconds between 1904-01-01 and 1970-01-01
        let targetSecondsSince1904 = Int64(targetDate.timeIntervalSince1970) + macEpochOffset
        guard targetSecondsSince1904 >= 0 else { return }

        let fileSize = try fileHandle.seekToEnd()
        var patchedCount = 0

        func patchContainer(offset: UInt64, length: UInt64) throws {
            let endOffset = offset + length
            var currentOffset = offset

            while currentOffset + 8 <= endOffset {
                try fileHandle.seek(toOffset: currentOffset)
                guard let headerData = try fileHandle.read(upToCount: 8), headerData.count == 8 else {
                    break
                }

                var size = UInt64(UInt32(bigEndian: headerData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }))
                let typeStr = String(bytes: headerData.suffix(4), encoding: .ascii) ?? ""
                var headerLength: UInt64 = 8

                if size == 1 {
                    guard let extData = try fileHandle.read(upToCount: 8), extData.count == 8 else { break }
                    size = UInt64(bigEndian: extData.withUnsafeBytes { $0.load(as: UInt64.self) })
                    headerLength = 16
                } else if size == 0 {
                    size = endOffset - currentOffset
                }

                if size < headerLength || currentOffset + size > endOffset { break }

                let payloadOffset = currentOffset + headerLength
                let payloadSize = size - headerLength

                if typeStr == "moov" || typeStr == "trak" || typeStr == "mdia" {
                    try patchContainer(offset: payloadOffset, length: payloadSize)
                } else if typeStr == "mvhd" || typeStr == "tkhd" || typeStr == "mdhd" {
                    if payloadSize >= 12 {
                        try fileHandle.seek(toOffset: payloadOffset)
                        guard let verData = try fileHandle.read(upToCount: 4), verData.count == 4 else {
                            currentOffset += size
                            continue
                        }
                        let version = verData[0]

                        if version == 0 {
                            var cTime = UInt32(clamping: targetSecondsSince1904).bigEndian
                            var mTime = cTime
                            let patchData = withUnsafeBytes(of: &cTime) { Data($0) } + withUnsafeBytes(of: &mTime) { Data($0) }
                            try fileHandle.seek(toOffset: payloadOffset + 4)
                            try fileHandle.write(contentsOf: patchData)
                            patchedCount += 1
                        } else if version == 1 && payloadSize >= 20 {
                            var cTime = UInt64(targetSecondsSince1904).bigEndian
                            var mTime = cTime
                            let patchData = withUnsafeBytes(of: &cTime) { Data($0) } + withUnsafeBytes(of: &mTime) { Data($0) }
                            try fileHandle.seek(toOffset: payloadOffset + 4)
                            try fileHandle.write(contentsOf: patchData)
                            patchedCount += 1
                        }
                    }
                }
                currentOffset += size
            }
        }

        try patchContainer(offset: 0, length: fileSize)
        guard patchedCount > 0 else {
            throw NSError(domain: "ExifMetadataService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to patch QuickTime container date tags (no header atoms found)"])
        }
    }

    /// Extract creation date from QuickTime/MP4 container 'mvhd' atom
    func parseContainerCreationDate(from fileURL: URL) -> Date? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fileHandle.close() }

        let macEpochOffset: Int64 = 2_082_844_800
        guard let fileSize = try? fileHandle.seekToEnd() else { return nil }

        func findCreationTime(offset: UInt64, length: UInt64) -> Date? {
            let endOffset = offset + length
            var currentOffset = offset

            while currentOffset + 8 <= endOffset {
                guard (try? fileHandle.seek(toOffset: currentOffset)) != nil,
                      let headerData = try? fileHandle.read(upToCount: 8), headerData.count == 8 else {
                    break
                }

                var size = UInt64(UInt32(bigEndian: headerData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }))
                let typeStr = String(bytes: headerData.suffix(4), encoding: .ascii) ?? ""
                var headerLength: UInt64 = 8

                if size == 1 {
                    guard let extData = try? fileHandle.read(upToCount: 8), extData.count == 8 else { break }
                    size = UInt64(bigEndian: extData.withUnsafeBytes { $0.load(as: UInt64.self) })
                    headerLength = 16
                } else if size == 0 {
                    size = endOffset - currentOffset
                }

                if size < headerLength || currentOffset + size > endOffset { break }

                let payloadOffset = currentOffset + headerLength
                let payloadSize = size - headerLength

                if typeStr == "moov" {
                    return findCreationTime(offset: payloadOffset, length: payloadSize)
                } else if typeStr == "mvhd" && payloadSize >= 8 {
                    guard (try? fileHandle.seek(toOffset: payloadOffset)) != nil,
                          let verData = try? fileHandle.read(upToCount: 4), verData.count == 4 else {
                        return nil
                    }
                    let version = verData[0]
                    if version == 0 && payloadSize >= 12 {
                        guard let timeData = try? fileHandle.read(upToCount: 4), timeData.count == 4 else { return nil }
                        let cTime = UInt32(bigEndian: timeData.withUnsafeBytes { $0.load(as: UInt32.self) })
                        let ts = Int64(cTime) - macEpochOffset
                        return Date(timeIntervalSince1970: TimeInterval(ts))
                    } else if version == 1 && payloadSize >= 20 {
                        guard let timeData = try? fileHandle.read(upToCount: 8), timeData.count == 8 else { return nil }
                        let cTime = UInt64(bigEndian: timeData.withUnsafeBytes { $0.load(as: UInt64.self) })
                        let ts = Int64(cTime) - macEpochOffset
                        return Date(timeIntervalSince1970: TimeInterval(ts))
                    }
                }
                currentOffset += size
            }
            return nil
        }

        return findCreationTime(offset: 0, length: fileSize)
    }

    private func formatISO6709(location: CLLocation) -> String {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let alt = location.altitude
        let latSign = lat >= 0 ? "+" : "-"
        let lonSign = lon >= 0 ? "+" : "-"
        let altSign = alt >= 0 ? "+" : "-"

        let latStr = String(format: "%@%07.4f", latSign, abs(lat))
        let lonStr = String(format: "%@%08.4f", lonSign, abs(lon))

        if abs(alt) > 0.001 {
            let altStr = String(format: "%@%.3f", altSign, abs(alt))
            return "\(latStr)\(lonStr)\(altStr)/"
        } else {
            return "\(latStr)\(lonStr)/"
        }
    }

    private func parseISO6709(_ string: String) -> CLLocation? {
        var str = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasSuffix("/") {
            str.removeLast()
        }
        let pattern = "^([+-]\\d+(?:\\.\\d+)?)([+-]\\d+(?:\\.\\d+)?)(?:([+-]\\d+(?:\\.\\d+)?))?$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = str as NSString
        guard let match = regex.firstMatch(in: str, range: NSRange(location: 0, length: nsString.length)) else { return nil }

        let latStr = nsString.substring(with: match.range(at: 1))
        let lonStr = nsString.substring(with: match.range(at: 2))
        guard let lat = Double(latStr), let lon = Double(lonStr) else { return nil }

        var alt: Double = 0.0
        if match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound {
            let altStr = nsString.substring(with: match.range(at: 3))
            alt = Double(altStr) ?? 0.0
        }
        return CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: alt, horizontalAccuracy: 0, verticalAccuracy: 0, timestamp: Date())
    }

    /// Read comprehensive EXIF and system metadata from image data
    func parseMetadata(
        from data: Data,
        asset: PHAsset,
        filename: String
    ) -> PhotoExifMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return fallbackMetadata(for: asset, filename: filename, byteCount: Int64(data.count))
        }

        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let typeIdentifier = CGImageSourceGetType(source) as String? ?? "public.image"

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        // Pixel dimensions (apply EXIF orientation swap for 90°/270° rotated images)
        let dims = Self.orientedPixelDimensions(
            from: properties,
            fallbackWidth: asset.pixelWidth,
            fallbackHeight: asset.pixelHeight
        )
        let width = dims.width
        let height = dims.height

        // Camera info
        let extInfo = asset.photosAppExtendedAttributesInfo
        let make = ((tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? extInfo.cameraMake
        let model = ((tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? extInfo.cameraModel
        let lensModel = ((exif?[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? extInfo.lensModel

        // Capture settings
        let focalLength = exif?[kCGImagePropertyExifFocalLength] as? Double
        let focalLength35mm = exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
        let aperture = exif?[kCGImagePropertyExifFNumber] as? Double
        let shutterSpeed = exif?[kCGImagePropertyExifExposureTime] as? Double
        let isoValues = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int]
        let iso = isoValues?.first ?? (exif?[kCGImagePropertyExifISOSpeed] as? Int)
        let exposureBias = exif?[kCGImagePropertyExifExposureBiasValue] as? Double
        let flashFired: Bool? = {
            if let flashVal = exif?[kCGImagePropertyExifFlash] as? Int {
                return (flashVal & 1) != 0
            }
            return nil
        }()
        let colorSpace = properties[kCGImagePropertyColorModel] as? String

        // Dates & Timezone
        let embeddedDateStr = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)

        var offsetTimeStr = (exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifOffsetTime] as? String)
            ?? (exif?[kCGImagePropertyExifOffsetTimeDigitized] as? String)

        let rawOffsets: (original: String?, standard: String?, digitized: String?)?
        if offsetTimeStr == nil {
            rawOffsets = parseRawExifOffsets(from: data)
            offsetTimeStr = rawOffsets?.original ?? rawOffsets?.standard ?? rawOffsets?.digitized
        } else {
            rawOffsets = nil
        }

        let exifTimeZone = parseTimezone(fromOffset: offsetTimeStr)
        // Photos app is the source of truth for current timezone
        let effectiveTimeZone = asset.photosAppTimeZone ?? exifTimeZone ?? .current

        // Determine authentic original timezone
        let originalTimeZone: TimeZone = {
            if let exifTZ = exifTimeZone {
                return exifTZ
            }
            if asset.isPhotosAppTimeZoneAdjusted {
                return asset.photosAppOriginalTimeZone ?? .current
            } else {
                return asset.photosAppTimeZone ?? .current
            }
        }()

        var embeddedDate = embeddedDateStr.flatMap { parseExifDateString($0, in: originalTimeZone) }
        if embeddedDate == nil {
            embeddedDate = extInfo.originalDate
        }

        // Check if date was adjusted: compare asset creation date with embedded EXIF date,
        // or check if timezone was adjusted in Photos
        let isDateDiff = checkIfDateAdjusted(
            assetCreationDate: asset.creationDate,
            embeddedDateStr: embeddedDateStr,
            timeZone: effectiveTimeZone
        )
        var isDateAdjusted = isDateDiff || asset.isPhotosAppTimeZoneAdjusted
        if !isDateAdjusted, let origDate = extInfo.originalDate, let curDate = asset.creationDate {
            if abs(curDate.timeIntervalSince(origDate)) > 1.0 {
                isDateAdjusted = true
            }
        }

        // Check if saved from other apps
        let isSavedFromOtherApps = checkIfSavedFromOtherApps(
            asset: asset,
            make: make,
            model: model,
            filename: filename,
            exifDict: exif
        )

        // GPS Location
        let originalLocation = parseGPSLocation(gpsDict: gps) ?? extInfo.originalLocation
        var isGPSAdjusted = checkIfGPSAdjusted(assetLocation: asset.location, exifLocation: originalLocation)
        if !isGPSAdjusted, let curLoc = asset.location, let origLoc = extInfo.originalLocation {
            if curLoc.distance(from: origLoc) > 10.0 {
                isGPSAdjusted = true
            }
        }
        // If the GPS location is adjusted in Photos app, show the adjusted location in detail view instead of the original location
        let effectiveLocation = isGPSAdjusted ? asset.location : (asset.location ?? originalLocation)

        let effectiveOffsetString = DateFormatters.exifTimezoneOffset(for: asset.creationDate ?? Date(), in: effectiveTimeZone)
        let hasEmbeddedTimeZone = (exifTimeZone != nil)
        let rawDateAndGPSFields = extractImageRawDateAndGPSFields(
            data: data,
            properties: properties,
            exif: exif,
            tiff: tiff,
            gps: gps,
            rawOffsets: rawOffsets
        )

        return PhotoExifMetadata(
            filename: filename,
            fileSizeString: ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file),
            fileByteCount: Int64(data.count),
            fileTypeString: (typeIdentifier as NSString).pathExtension.uppercased().isEmpty ? "IMAGE" : (typeIdentifier as NSString).pathExtension.uppercased(),
            pixelWidth: width,
            pixelHeight: height,
            creationDate: asset.creationDate,
            embeddedDate: embeddedDate,
            isDateAdjusted: isDateAdjusted,
            isEdited: asset.hasAdjustments,
            timeZone: effectiveTimeZone,
            originalTimeZone: originalTimeZone,
            offsetTimeString: effectiveOffsetString,
            cameraMake: make,
            cameraModel: model,
            lensModel: lensModel,
            focalLength: focalLength,
            focalLength35mm: focalLength35mm,
            aperture: aperture,
            shutterSpeed: shutterSpeed,
            iso: iso,
            exposureBias: exposureBias,
            flashFired: flashFired,
            colorSpace: colorSpace,
            isSavedFromOtherApps: isSavedFromOtherApps,
            appOriginHint: isSavedFromOtherApps ? identifyAppOrigin(filename: filename, make: make, model: model) : nil,
            location: effectiveLocation,
            originalLocation: originalLocation,
            isGPSAdjusted: isGPSAdjusted,
            altitude: effectiveLocation?.altitude,
            heading: effectiveLocation?.course,
            speed: effectiveLocation?.speed,
            hasEmbeddedTimeZone: hasEmbeddedTimeZone,
            rawDateAndGPSFields: rawDateAndGPSFields
        )
    }

    /// Fast metadata evaluation for list filtering
    nonisolated func evaluateMetadataQuick(
        data: Data?,
        asset: PHAsset,
        filename: String
    ) -> (embeddedDate: Date?, isDateAdjusted: Bool, isGPSAdjusted: Bool, isFromOtherApps: Bool, hasEmbeddedTimeZone: Bool, timeZone: TimeZone, isDrifted: Bool)? {
        let extInfo = asset.photosAppExtendedAttributesInfo

        // Do not fallback or guess when photo data is missing. Return nil so caller can retry.
        guard let data = data, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        let embeddedDateStr = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        var offsetTimeStr = (exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifOffsetTime] as? String)
            ?? (exif?[kCGImagePropertyExifOffsetTimeDigitized] as? String)
        if offsetTimeStr == nil {
            let rawOffsets = parseRawExifOffsets(from: data)
            offsetTimeStr = rawOffsets?.original ?? rawOffsets?.standard ?? rawOffsets?.digitized
        }
        let exifTimeZone = parseTimezone(fromOffset: offsetTimeStr)
        let effectiveTimeZone = asset.photosAppTimeZone ?? exifTimeZone ?? .current
        let originalTimeZone: TimeZone = {
            if let exifTZ = exifTimeZone {
                return exifTZ
            }
            if asset.isPhotosAppTimeZoneAdjusted {
                return asset.photosAppOriginalTimeZone ?? .current
            } else {
                return asset.photosAppTimeZone ?? .current
            }
        }()
        var embeddedDate = embeddedDateStr.flatMap { parseExifDateString($0, in: originalTimeZone) }
        if embeddedDate == nil {
            embeddedDate = extInfo.originalDate
        }

        let make = (tiff?[kCGImagePropertyTIFFMake] as? String) ?? extInfo.cameraMake
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String) ?? extInfo.cameraModel

        let exifLocation = parseGPSLocation(gpsDict: gps) ?? extInfo.originalLocation
        var isGPSAdjusted = checkIfGPSAdjusted(assetLocation: asset.location, exifLocation: exifLocation)
        if !isGPSAdjusted, let curLoc = asset.location, let origLoc = extInfo.originalLocation {
            if curLoc.distance(from: origLoc) > 10.0 {
                isGPSAdjusted = true
            }
        }

        let isDateDiff = checkIfDateAdjusted(
            assetCreationDate: asset.creationDate,
            embeddedDateStr: embeddedDateStr,
            timeZone: effectiveTimeZone
        )
        var isDateAdjusted = isDateDiff || asset.isPhotosAppTimeZoneAdjusted
        if !isDateAdjusted, let origDate = extInfo.originalDate, let curDate = asset.creationDate {
            if abs(curDate.timeIntervalSince(origDate)) > 1.0 {
                isDateAdjusted = true
            }
        }

        let isFromOtherApps = checkIfSavedFromOtherApps(
            asset: asset,
            make: make,
            model: model,
            filename: filename,
            exifDict: exif
        )
        let hasEmbeddedTimeZone = (exifTimeZone != nil)

        return (embeddedDate, isDateAdjusted, isGPSAdjusted, isFromOtherApps, hasEmbeddedTimeZone, effectiveTimeZone, false)
    }

    // MARK: - Embed Metadata for Export

    /// Embed adjusted date, time, timezone, and optional adjusted GPS location directly into image EXIF/TIFF headers.
    /// Uses lossless metadata copy (CGImageDestinationCopyImageSource) whenever possible to avoid decoding/recompressing
    /// image data and preventing file size inflation (e.g. avoiding turning a 1.2MB JPEG into 1.7MB).
    func embedAdjustedMetadata(
        imageData: Data,
        targetDate: Date? = nil,
        timeZone: TimeZone = .current,
        adjustedLocation: CLLocation? = nil,
        isGPSAdjusted: Bool = false,
        clockwiseRotationSteps: Int = 0
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            throw NSError(domain: "ExifMetadataService", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create image source from photo data"])
        }

        let steps = ((clockwiseRotationSteps % 4) + 4) % 4
        let sourceProps = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let currentOrientation = (sourceProps[kCGImagePropertyOrientation] as? Int)
            ?? ((sourceProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? Int)
            ?? 1
        let targetOrientation: Int? = steps == 0
            ? nil
            : Self.rotateExifOrientation(currentOrientation, clockwiseSteps: steps)

        let typeStr = type as String
        let supportsExifOrientationLossless = typeStr == "public.jpeg" ||
                                              typeStr == "public.heic" ||
                                              typeStr == "public.heif" ||
                                              typeStr == "public.tiff"

        // 1. Primary approach: Lossless copy via CGImageDestinationCopyImageSource.
        // This copies the original image bitstream directly without decoding or re-encoding pixels,
        // preserving exact image quality and preventing file size inflation.
        if (steps == 0 || supportsExifOrientationLossless),
           let losslessData = tryLosslessEmbedAdjustedMetadata(
               source: source,
               type: type,
               imageData: imageData,
               targetDate: targetDate,
               timeZone: timeZone,
               adjustedLocation: adjustedLocation,
               isGPSAdjusted: isGPSAdjusted,
               targetOrientation: targetOrientation
           ) {
            if let expectedOri = targetOrientation {
                if let verifySource = CGImageSourceCreateWithData(losslessData as CFData, nil),
                   let verifyProps = CGImageSourceCopyPropertiesAtIndex(verifySource, 0, nil) as? [CFString: Any],
                   let writtenOri = (verifyProps[kCGImagePropertyOrientation] as? Int)
                    ?? ((verifyProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? Int),
                   writtenOri == expectedOri {
                    return losslessData
                }
            } else {
                return losslessData
            }
        }

        // 2. Fallback: CGImageDestinationAddImageFromSource (or pixel rotation for formats/fallback with rotation)
        return try fallbackEmbedAdjustedMetadata(
            source: source,
            type: type,
            targetDate: targetDate,
            timeZone: timeZone,
            adjustedLocation: adjustedLocation,
            isGPSAdjusted: isGPSAdjusted,
            clockwiseRotationSteps: steps,
            imageData: imageData
        )
    }

    private func tryLosslessEmbedAdjustedMetadata(
        source: CGImageSource,
        type: CFString,
        imageData: Data,
        targetDate: Date?,
        timeZone: TimeZone,
        adjustedLocation: CLLocation?,
        isGPSAdjusted: Bool,
        targetOrientation: Int? = nil
    ) -> Data? {
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, type, 0, nil) else {
            return nil
        }

        let existingMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let mutableMetadata = existingMetadata.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()

        // Strip existing PNG eXIf and XMP iTXt chunks from the pixel source before copying:
        // ImageIO's CGImageDestinationCopyImageSource on PNGs otherwise leaves stale OffsetTime/OffsetTimeOriginal
        // in existing eXIf chunks (updating only OffsetTimeDigitized) and leaves trailing bytes when shrinking XMP iTXt.
        let copySource: CGImageSource = {
            guard (type as String) == "public.png" else { return source }
            let cleanData = stripPNGMetadataChunks(imageData)
            return CGImageSourceCreateWithData(cleanData as CFData, nil) ?? source
        }()

        var options: [CFString: Any] = [:]

        if let targetDate = targetDate {
            let exifDateFormatter = DateFormatter()
            exifDateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            exifDateFormatter.timeZone = timeZone
            exifDateFormatter.locale = Locale(identifier: "en_US_POSIX")
            let formattedDateTime = exifDateFormatter.string(from: targetDate)
            let timezoneOffset = DateFormatters.exifTimezoneOffset(for: targetDate, in: timeZone)

            CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, formattedDateTime as CFString)
            CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, formattedDateTime as CFString)

            CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTime, timezoneOffset as CFString)
            CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeOriginal, timezoneOffset as CFString)
            CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeDigitized, timezoneOffset as CFString)

            CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime, formattedDateTime as CFString)

            // Explicitly set XMP date tags using ISO-8601 with timezone (e.g. 2026-07-23T17:53:10-07:00) per XMP standard.
            // ImageIO maps EXIF/TIFF properties into XMP chunks for containers like PNG, which would otherwise
            // leave EXIF-formatted strings (yyyy:MM:dd HH:mm:ss) in XMP date fields.
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.timeZone = timeZone
            isoFormatter.formatOptions = [.withInternetDateTime]
            let isoDateString = isoFormatter.string(from: targetDate)

            let exifNamespace = "http://ns.adobe.com/exif/1.0/" as CFString
            let exifPrefix = "exif" as CFString
            if let tagOrig = CGImageMetadataTagCreate(exifNamespace, exifPrefix, "DateTimeOriginal" as CFString, .string, isoDateString as CFString) {
                CGImageMetadataSetTagWithPath(mutableMetadata, nil, "exif:DateTimeOriginal" as CFString, tagOrig)
            }
            if let tagDig = CGImageMetadataTagCreate(exifNamespace, exifPrefix, "DateTimeDigitized" as CFString, .string, isoDateString as CFString) {
                CGImageMetadataSetTagWithPath(mutableMetadata, nil, "exif:DateTimeDigitized" as CFString, tagDig)
            }

            let xmpNamespace = "http://ns.adobe.com/xap/1.0/" as CFString
            let xmpPrefix = "xmp" as CFString
            if let tagModify = CGImageMetadataTagCreate(xmpNamespace, xmpPrefix, "ModifyDate" as CFString, .string, isoDateString as CFString) {
                CGImageMetadataSetTagWithPath(mutableMetadata, nil, "xmp:ModifyDate" as CFString, tagModify)
            }
            if let tagCreate = CGImageMetadataTagCreate(xmpNamespace, xmpPrefix, "CreateDate" as CFString, .string, isoDateString as CFString) {
                CGImageMetadataSetTagWithPath(mutableMetadata, nil, "xmp:CreateDate" as CFString, tagCreate)
            }

            let photoshopNamespace = "http://ns.adobe.com/photoshop/1.0/" as CFString
            let photoshopPrefix = "photoshop" as CFString
            if let tagCreated = CGImageMetadataTagCreate(photoshopNamespace, photoshopPrefix, "DateCreated" as CFString, .string, isoDateString as CFString) {
                CGImageMetadataSetTagWithPath(mutableMetadata, nil, "photoshop:DateCreated" as CFString, tagCreated)
            }
        }

        if isGPSAdjusted {
            if let loc = adjustedLocation {
                let lat = loc.coordinate.latitude
                let lon = loc.coordinate.longitude
                CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, abs(lat) as CFNumber)
                CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, (lat >= 0 ? "N" : "S") as CFString)
                CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, abs(lon) as CFNumber)
                CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, (lon >= 0 ? "E" : "W") as CFString)

                if loc.altitude != 0 {
                    CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSAltitude, abs(loc.altitude) as CFNumber)
                    CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSAltitudeRef, (loc.altitude >= 0 ? 0 : 1) as CFNumber)
                }
            } else {
                options[kCGImageMetadataShouldExcludeGPS] = true as CFBoolean
            }
        }

        if let targetOrientation {
            CGImageMetadataSetValueMatchingImageProperty(mutableMetadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, NSNumber(value: targetOrientation))
        }

        options[kCGImageDestinationMetadata] = mutableMetadata

        var error: Unmanaged<CFError>?
        let success = CGImageDestinationCopyImageSource(destination, copySource, options as CFDictionary, &error)
        guard success else {
            return nil
        }
        return outputData as Data
    }

    /// Removes existing `eXIf` and XMP `iTXt` chunks from a PNG byte stream while preserving image chunks and CRCs intact.
    private func stripPNGMetadataChunks(_ data: Data) -> Data {
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let xmpKeyword = Data("XML:com.adobe.xmp\0".utf8)
        guard data.starts(with: pngSignature) else { return data }

        var result = Data()
        result.reserveCapacity(data.count)
        result.append(pngSignature)

        var pos = pngSignature.count
        while pos + 12 <= data.count {
            let length = (Int(data[pos]) << 24)
                | (Int(data[pos + 1]) << 16)
                | (Int(data[pos + 2]) << 8)
                | Int(data[pos + 3])
            let chunkTotalLength = 12 + length
            guard length >= 0, pos + chunkTotalLength <= data.count else {
                return data
            }

            let typeStart = pos + 4
            let typeEnd = pos + 8
            let chunkType = String(bytes: data[typeStart..<typeEnd], encoding: .ascii)
            let isXMPiTXt: Bool = {
                guard chunkType == "iTXt" else { return false }
                let payloadStart = pos + 8
                let payloadEnd = payloadStart + length
                return data[payloadStart..<payloadEnd].starts(with: xmpKeyword)
            }()

            if chunkType != "eXIf" && !isXMPiTXt {
                result.append(data[pos..<(pos + chunkTotalLength)])
            }
            pos += chunkTotalLength
        }
        return result
    }

    private func fallbackEmbedAdjustedMetadata(
        source: CGImageSource,
        type: CFString,
        targetDate: Date?,
        timeZone: TimeZone,
        adjustedLocation: CLLocation?,
        isGPSAdjusted: Bool,
        clockwiseRotationSteps: Int = 0,
        imageData: Data
    ) throws -> Data {
        var rootProperties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

        if let targetDate = targetDate {
            let exifDateFormatter = DateFormatter()
            exifDateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            exifDateFormatter.timeZone = timeZone
            exifDateFormatter.locale = Locale(identifier: "en_US_POSIX")

            let iptcDateFormatter = DateFormatter()
            iptcDateFormatter.dateFormat = "yyyyMMdd"
            iptcDateFormatter.timeZone = timeZone
            iptcDateFormatter.locale = Locale(identifier: "en_US_POSIX")

            let iptcTimeFormatter = DateFormatter()
            iptcTimeFormatter.dateFormat = "HHmmss"
            iptcTimeFormatter.timeZone = timeZone
            iptcTimeFormatter.locale = Locale(identifier: "en_US_POSIX")

            let formattedDateTime = exifDateFormatter.string(from: targetDate)
            let timezoneOffset = DateFormatters.exifTimezoneOffset(for: targetDate, in: timeZone)
            let iptcDate = iptcDateFormatter.string(from: targetDate)
            let iptcTime = iptcTimeFormatter.string(from: targetDate)

            var exifDict = (rootProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
            exifDict[kCGImagePropertyExifDateTimeOriginal] = formattedDateTime
            exifDict[kCGImagePropertyExifDateTimeDigitized] = formattedDateTime
            exifDict[kCGImagePropertyExifOffsetTime] = timezoneOffset
            exifDict[kCGImagePropertyExifOffsetTimeOriginal] = timezoneOffset
            exifDict[kCGImagePropertyExifOffsetTimeDigitized] = timezoneOffset
            rootProperties[kCGImagePropertyExifDictionary] = exifDict

            var tiffDict = (rootProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            tiffDict[kCGImagePropertyTIFFDateTime] = formattedDateTime
            rootProperties[kCGImagePropertyTIFFDictionary] = tiffDict

            var iptcDict = (rootProperties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
            iptcDict[kCGImagePropertyIPTCDateCreated] = iptcDate
            iptcDict[kCGImagePropertyIPTCTimeCreated] = iptcTime
            rootProperties[kCGImagePropertyIPTCDictionary] = iptcDict
        }

        if isGPSAdjusted {
            if let loc = adjustedLocation {
                var gpsDict = (rootProperties[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]
                let lat = loc.coordinate.latitude
                let lon = loc.coordinate.longitude
                gpsDict[kCGImagePropertyGPSLatitude] = abs(lat)
                gpsDict[kCGImagePropertyGPSLatitudeRef] = lat >= 0 ? "N" : "S"
                gpsDict[kCGImagePropertyGPSLongitude] = abs(lon)
                gpsDict[kCGImagePropertyGPSLongitudeRef] = lon >= 0 ? "E" : "W"
                if loc.altitude != 0 {
                    gpsDict[kCGImagePropertyGPSAltitude] = abs(loc.altitude)
                    gpsDict[kCGImagePropertyGPSAltitudeRef] = loc.altitude >= 0 ? 0 : 1
                }
                rootProperties[kCGImagePropertyGPSDictionary] = gpsDict
            } else {
                rootProperties.removeValue(forKey: kCGImagePropertyGPSDictionary)
            }
        }

        if clockwiseRotationSteps != 0 {
            return try Self.rotateImageData(
                imageData,
                targetType: type,
                clockwiseSteps: clockwiseRotationSteps,
                overriddenProperties: rootProperties
            )
        }

        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, type, 1, nil) else {
            throw NSError(domain: "ExifMetadataService", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination for photo metadata embedding"])
        }

        CGImageDestinationAddImageFromSource(destination, source, 0, rootProperties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ExifMetadataService", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize image destination for photo metadata embedding"])
        }

        return outputData as Data
    }

    // MARK: - Private Helpers

    private func parseExifDateString(_ str: String, in timeZone: TimeZone = .current) -> Date? {
        // Standard EXIF format: "2024:05:18 14:30:22"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        if let date = formatter.date(from: str) {
            return date
        }

        // Fallback for ISO format: "2024-05-18T14:30:22"
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = timeZone
        if let date = isoFormatter.date(from: str) {
            return date
        }

        return nil
    }

    private func parseTimezone(fromOffset offsetStr: String?) -> TimeZone? {
        guard let offsetStr = offsetStr else { return nil }
        let clean = offsetStr.replacingOccurrences(of: ":", with: "")
        guard let sign = clean.first, (sign == "+" || sign == "-") else { return nil }
        guard let totalHours = Int(clean.dropFirst()) else { return nil }

        let hours = totalHours / 100
        let minutes = totalHours % 100
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    private func checkIfDateAdjusted(assetCreationDate: Date?, embeddedDateStr: String?, timeZone: TimeZone) -> Bool {
        guard let assetDate = assetCreationDate, let embeddedStr = embeddedDateStr, !embeddedStr.isEmpty else {
            return false
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let assetDateStr = formatter.string(from: assetDate)

        // Compare formatted date string in the asset's timezone with the embedded EXIF timestamp
        return assetDateStr != embeddedStr
    }

    private func checkIfSavedFromOtherApps(
        asset: PHAsset,
        make: String?,
        model: String?,
        filename: String,
        exifDict: [CFString: Any]?
    ) -> Bool {
        // Screenshots are by definition captured by the system, not camera photo
        if asset.mediaSubtypes.contains(.photoScreenshot) {
            return true
        }

        let makeLower = (make ?? "").lowercased()
        let modelLower = (model ?? "").lowercased()
        let filenameLower = filename.lowercased()

        // If taken with iPhone camera, make contains "apple" and model contains "iphone"
        let isAppleCamera = makeLower.contains("apple") && modelLower.contains("iphone")
        if isAppleCamera {
            return false
        }

        // Known third-party app signatures or missing camera hardware info
        if make == nil && model == nil {
            return true
        }

        // Non-camera files (e.g. downloaded from WhatsApp, Telegram, Instagram, Safari)
        if filenameLower.contains("whatsapp") ||
            filenameLower.contains("telegram") ||
            filenameLower.contains("wechat") ||
            filenameLower.contains("download") ||
            filenameLower.contains("screenshot") {
            return true
        }

        return !isAppleCamera
    }

    private func identifyAppOrigin(filename: String, make: String?, model: String?) -> String {
        let fn = filename.lowercased()
        if fn.contains("whatsapp") { return "WhatsApp" }
        if fn.contains("telegram") { return "Telegram" }
        if fn.contains("wechat") { return "WeChat" }
        if fn.contains("instagram") { return "Instagram" }
        if fn.contains("screenshot") { return "Screenshot" }
        if let model = model, !model.isEmpty {
            return model
        }
        return "Third-Party App / Web"
    }

    private func checkIfGPSAdjusted(assetLocation: CLLocation?, exifLocation: CLLocation?) -> Bool {
        if let assetLoc = assetLocation, let exifLoc = exifLocation {
            // If distance between Photos app location and original EXIF location > 10 meters, location was adjusted
            return assetLoc.distance(from: exifLoc) > 10.0
        } else if assetLocation != nil && exifLocation == nil {
            // Location was added in Photos app
            return true
        } else if assetLocation == nil && exifLocation != nil {
            // Location was removed in Photos app
            return true
        }
        return false
    }

    private func parseGPSLocation(gpsDict: [CFString: Any]?) -> CLLocation? {
        guard let gps = gpsDict else { return nil }
        guard let latVal = gps[kCGImagePropertyGPSLatitude] as? Double,
              let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
              let lonVal = gps[kCGImagePropertyGPSLongitude] as? Double,
              let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String else {
            return nil
        }

        let latitude = latRef.uppercased() == "S" ? -abs(latVal) : abs(latVal)
        let longitude = lonRef.uppercased() == "W" ? -abs(lonVal) : abs(lonVal)

        let altitude = (gps[kCGImagePropertyGPSAltitude] as? Double) ?? 0.0

        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            timestamp: Date()
        )
    }

    private func fallbackMetadata(
        for asset: PHAsset,
        filename: String,
        byteCount: Int64
    ) -> PhotoExifMetadata {
        let extInfo = asset.photosAppExtendedAttributesInfo
        let appTZ = asset.photosAppTimeZone ?? .current
        var isDateAdjusted = asset.isPhotosAppTimeZoneAdjusted
        if !isDateAdjusted, let origDate = extInfo.originalDate, let curDate = asset.creationDate {
            if abs(curDate.timeIntervalSince(origDate)) > 1.0 {
                isDateAdjusted = true
            }
        }
        let isGPSAdjusted: Bool
        if let curLoc = asset.location, let origLoc = extInfo.originalLocation {
            isGPSAdjusted = curLoc.distance(from: origLoc) > 10.0
        } else {
            isGPSAdjusted = false
        }

        return PhotoExifMetadata(
            filename: filename,
            fileSizeString: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file),
            fileByteCount: byteCount,
            fileTypeString: "IMAGE",
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            creationDate: asset.creationDate,
            embeddedDate: extInfo.originalDate,
            isDateAdjusted: isDateAdjusted,
            isEdited: asset.hasAdjustments,
            timeZone: appTZ,
            originalTimeZone: appTZ,
            offsetTimeString: DateFormatters.exifTimezoneOffset(for: asset.creationDate ?? Date(), in: appTZ),
            cameraMake: extInfo.cameraMake,
            cameraModel: extInfo.cameraModel,
            lensModel: extInfo.lensModel,
            focalLength: nil,
            focalLength35mm: nil,
            aperture: nil,
            shutterSpeed: nil,
            iso: nil,
            exposureBias: nil,
            flashFired: nil,
            colorSpace: nil,
            isSavedFromOtherApps: asset.mediaSubtypes.contains(.photoScreenshot),
            appOriginHint: nil,
            location: asset.location ?? extInfo.originalLocation,
            originalLocation: extInfo.originalLocation ?? asset.location,
            isGPSAdjusted: isGPSAdjusted,
            altitude: asset.location?.altitude,
            heading: nil,
            speed: nil
        )
    }

    // MARK: - Applied Edits Extraction

    /// Extract user-friendly descriptions of edits applied to a photo/video (e.g. Cropping, Rotation, Portrait, Filter)
    func extractAppliedEdits(for asset: PHAsset) async -> [String] {
        guard asset.hasAdjustments else { return [] }

        let adjustmentData: PHAdjustmentData? = await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.canHandleAdjustmentData = { _ in true }
            options.isNetworkAccessAllowed = true

            asset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input?.adjustmentData)
            }
        }

        guard let adj = adjustmentData else {
            return ["Edited"]
        }

        let edits = parseAdjustmentData(adj, asset: asset)
        return edits.isEmpty ? ["Edited"] : edits
    }

    func parseAdjustmentData(_ adj: PHAdjustmentData, asset: PHAsset? = nil) -> [String] {
        let rawData = adj.data
        let formatIdentifier = adj.formatIdentifier

        if formatIdentifier == PhotoLibraryService.rotationAdjustmentIdentifier {
            if let dict = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
                var edits = (dict["priorEdits"] as? [String]) ?? []
                let steps = (dict["clockwiseSteps"] as? Int) ?? 0
                if steps % 4 != 0 && !edits.contains("Rotation") {
                    edits.append("Rotation")
                }
                return edits
            }
            return ["Rotation"]
        }

        // 1. Check for specialized format identifiers (e.g. Markup)
        let lowerFormat = formatIdentifier.lowercased()
        if lowerFormat.contains("markup") || lowerFormat.contains("paperkit") || lowerFormat.contains("pencilkit") {
            return ["Markup"]
        }

        // 2. Try to decompress rawData (deflate/zlib), or fall back to rawData if uncompressed
        let payloadData = decompressZlibOrDeflate(rawData) ?? rawData

        // 3. Try JSON deserialization
        if let jsonObject = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
            let edits = parseAdjustmentsDictionary(jsonObject, asset: asset)
            if !edits.isEmpty {
                return edits
            }
        }

        // 4. Try PropertyList deserialization
        if let plist = try? PropertyListSerialization.propertyList(from: payloadData, options: [], format: nil) as? [String: Any] {
            let edits = parseAdjustmentsDictionary(plist, asset: asset)
            if !edits.isEmpty {
                return edits
            }
        }

        // 5. Handle known external apps or format identifiers
        if !formatIdentifier.starts(with: "com.apple") {
            let appName = friendlyAppName(for: formatIdentifier)
            return [appName]
        }

        return []
    }

    private func parseAdjustmentsDictionary(_ dict: [String: Any], asset: PHAsset? = nil) -> [String] {
        var results: [String] = []
        var seen = Set<String>()

        func addEdit(_ name: String) {
            if !seen.contains(name) {
                seen.insert(name)
                results.append(name)
            }
        }

        // Extract master dimensions and orientation if available from metadata or top-level dict
        let metadataDict = dict["metadata"] as? [String: Any]
        let masterWidth = (metadataDict?["masterWidth"] as? NSNumber)?.intValue
        let masterHeight = (metadataDict?["masterHeight"] as? NSNumber)?.intValue
        let metaOrientation = (metadataDict?["orientation"] as? NSNumber)?.intValue
            ?? (dict["orientation"] as? NSNumber)?.intValue ?? 0

        let adjustmentsList = (dict["adjustments"] as? [[String: Any]]) ?? []
        var hasCropAdjustment = false

        for item in adjustmentsList {
            guard let identifier = item["identifier"] as? String else { continue }
            let isEnabled = (item["enabled"] as? Bool) ?? true
            let settings = (item["settings"] as? [String: Any]) ?? [:]

            switch identifier {
            case "Crop":
                hasCropAdjustment = true

                // Angle straightening
                if let straightenAngle = (settings["straightenAngle"] as? NSNumber)?.doubleValue, abs(straightenAngle) > 0.0001 {
                    addEdit("Rotation")
                }
                // Perspective distortion
                if let pitch = (settings["pitch"] as? NSNumber)?.doubleValue, abs(pitch) > 0.0001 {
                    addEdit("Perspective")
                }
                if let yaw = (settings["yaw"] as? NSNumber)?.doubleValue, abs(yaw) > 0.0001 {
                    addEdit("Perspective")
                }
                if let cropOri = (settings["orientation"] as? NSNumber)?.intValue, [3, 6, 8].contains(cropOri) {
                    addEdit("Rotation")
                }

                // In Apple Photos:
                // - If enabled is false: user rotated or straightened using the crop tool without cropping.
                // - If enabled is true: user cropped the image.
                if !isEnabled {
                    addEdit("Rotation")
                } else {
                    addEdit("Cropping")
                }

            case "Orientation", "Rotate", "Rotation":
                if isEnabled { addEdit("Rotation") }

            case "Flip", "Mirror":
                if isEnabled { addEdit("Flip") }

            case "Markup", "PaperKit", "PencilKit", "Draw":
                if isEnabled { addEdit("Markup") }

            case "Portrait", "PortraitEffect", "DepthEffect", "Depth", "PortraitVideo":
                if isEnabled { addEdit("Portrait") }

            case "Effect", "Filter":
                if isEnabled { addEdit("Filter") }

            case "SmartTone", "Curves", "Levels":
                if isEnabled { addEdit("Light") }

            case "SmartColor", "SelectiveColor":
                if isEnabled { addEdit("Color") }

            case "SmartBW":
                if isEnabled { addEdit("Black & White") }

            case "WhiteBalance":
                if isEnabled { addEdit("White Balance") }

            case "Inpaint", "Retouch":
                if isEnabled { addEdit("Clean Up") }

            case "RedEye", "ApertureRedEye":
                if isEnabled { addEdit("Red-Eye") }

            case "SemanticStyle":
                if isEnabled { addEdit("Photographic Style") }

            case "AutoEnhance":
                if isEnabled { addEdit("Auto Enhance") }

            case "Trim":
                if isEnabled { addEdit("Trimming") }

            case "Mute":
                if isEnabled { addEdit("Mute") }

            case "Slomo", "SlowMotion", "SlomoAdjustment":
                if isEnabled { addEdit("Slow Motion") }

            case "CinematicAudio":
                if isEnabled { addEdit("Audio Mix") }

            case "AutoLoop", "VideoCrossfadeLoop":
                if isEnabled { addEdit("Live Photo Effect") }

            case "LivePhotoKeyFrame", "VideoPosterFrame":
                if isEnabled { addEdit("Key Photo") }

            case "Vignette":
                if isEnabled { addEdit("Vignette") }

            case "Sharpen", "Definition", "NoiseReduction", "Grain":
                if isEnabled { addEdit("Sharpen / Noise") }

            default:
                if isEnabled {
                    let cleaned = identifier.replacingOccurrences(of: "PI", with: "")
                        .replacingOccurrences(of: "AdjustmentKey", with: "")
                        .replacingOccurrences(of: "Adjustment", with: "")
                    if !cleaned.isEmpty && cleaned != "Source" {
                        addEdit(cleaned)
                    }
                }
            }
        }

        // Quick rotate from Photos share sheet or action menu where adjustments array is empty
        if !hasCropAdjustment && adjustmentsList.isEmpty {
            if [3, 6, 8].contains(metaOrientation) {
                if let mw = masterWidth, let mh = masterHeight, let pw = asset?.pixelWidth, let ph = asset?.pixelHeight, mw != mh, pw != ph {
                    if (mw > mh) != (pw > ph) {
                        addEdit("Rotation")
                    }
                }
            }
        }

        return results
    }

    private func decompressZlibOrDeflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        // Window bits to try:
        // -15: raw deflate (used by Photos com.apple.photo adjustmentData)
        // 15 + 32: zlib with automatic gzip/zlib header detection
        // 15: standard zlib header
        let windowBitsList: [Int32] = [-15, 15 + 32, 15]

        for windowBits in windowBitsList {
            var stream = z_stream()
            let initStatus = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initStatus == Z_OK else { continue }

            var decompressed = Data(capacity: data.count * 4)
            let bufferSize = 16384
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

            var currentStatus = Z_OK
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else { return }
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress)
                stream.avail_in = uInt(data.count)

                repeat {
                    stream.next_out = buffer
                    stream.avail_out = uInt(bufferSize)
                    currentStatus = inflate(&stream, Z_NO_FLUSH)
                    let bytesWritten = bufferSize - Int(stream.avail_out)
                    if bytesWritten > 0 {
                        decompressed.append(buffer, count: bytesWritten)
                    }
                } while currentStatus == Z_OK
            }

            buffer.deallocate()
            inflateEnd(&stream)

            if currentStatus == Z_STREAM_END && !decompressed.isEmpty {
                return decompressed
            }
        }
        return nil
    }

    private func friendlyAppName(for identifier: String) -> String {
        let lower = identifier.lowercased()
        if lower.contains("vsco") { return "VSCO" }
        if lower.contains("lightroom") { return "Lightroom" }
        if lower.contains("snapseed") { return "Snapseed" }
        if lower.contains("instagram") { return "Instagram" }
        if lower.contains("photoshop") { return "Photoshop" }
        if lower.contains("afterlight") { return "Afterlight" }
        if lower.contains("darkroom") { return "Darkroom" }

        if let last = identifier.components(separatedBy: ".").last, !last.isEmpty {
            return last.capitalized
        }
        return "Third-Party App"
    }

    // MARK: - Raw EXIF / QuickTime Date & GPS Fields Extraction

    /// Extract raw EXIF/TIFF/XMP/IPTC/PNG date & GPS fields from raw image data
    func extractImageRawDateAndGPSFields(from data: Data) -> [ExifRawField] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return []
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        return extractImageRawDateAndGPSFields(
            data: data,
            properties: properties,
            exif: exif,
            tiff: tiff,
            gps: gps
        )
    }

    func extractImageRawDateAndGPSFields(
        data: Data,
        properties: [CFString: Any],
        exif: [CFString: Any]?,
        tiff: [CFString: Any]?,
        gps: [CFString: Any]?,
        rawOffsets: (original: String?, standard: String?, digitized: String?)? = nil
    ) -> [ExifRawField] {
        var fields: [ExifRawField] = []

        func addField(_ label: String, _ value: String?) {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            fields.append(ExifRawField(label: label, value: v))
        }

        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let xmpTags = extractRawXMPTags(from: data)
        let rawGPS = parseRawGPSIFD(from: data)
        let resolvedOffsets: (original: String?, standard: String?, digitized: String?)? = {
            if let rawOffsets = rawOffsets { return rawOffsets }
            if exif?[kCGImagePropertyExifOffsetTime] == nil &&
               exif?[kCGImagePropertyExifOffsetTimeOriginal] == nil &&
               exif?[kCGImagePropertyExifOffsetTimeDigitized] == nil {
                return parseRawExifOffsets(from: data)
            }
            return nil
        }()

        // 1. Date/Time Original
        addField("Date/Time Original", exif?[kCGImagePropertyExifDateTimeOriginal] as? String)

        // 2. Date/Time Digitized
        let dateTimeDigitized = exif?[kCGImagePropertyExifDateTimeDigitized] as? String
        addField("Date/Time Digitized", dateTimeDigitized)

        // 3. Modify Date
        let modifyDate = (tiff?[kCGImagePropertyTIFFDateTime] as? String)
            ?? xmpTags["xmp:ModifyDate"].map { formatISOToExifDate($0) }
            ?? (png?[kCGImagePropertyPNGModificationTime] as? String)
        addField("Modify Date", modifyDate)

        // 4. Create Date
        let createDate = xmpTags["xmp:CreateDate"].map { formatISOToExifDate($0) }
            ?? dateTimeDigitized
            ?? (png?[kCGImagePropertyPNGCreationTime] as? String)
        addField("Create Date", createDate)

        // 5. Date Created
        var dateCreated = xmpTags["photoshop:DateCreated"].map { formatISOToExifDate($0) }
        if dateCreated == nil, let iptcDate = iptc?[kCGImagePropertyIPTCDateCreated] as? String, iptcDate.count == 8 {
            let y = iptcDate.prefix(4)
            let m = iptcDate.dropFirst(4).prefix(2)
            let d = iptcDate.dropFirst(6).prefix(2)
            if let iptcTime = iptc?[kCGImagePropertyIPTCTimeCreated] as? String, iptcTime.count >= 6 {
                let hh = iptcTime.prefix(2)
                let mm = iptcTime.dropFirst(2).prefix(2)
                let ss = iptcTime.dropFirst(4).prefix(2)
                dateCreated = "\(y):\(m):\(d) \(hh):\(mm):\(ss)"
            } else {
                dateCreated = "\(y):\(m):\(d)"
            }
        }
        addField("Date Created", dateCreated)

        // 6. Creation Date (QuickTime field; omitted for images unless present in XMP)

        // 7. Offset Time
        let offsetTimeVal = (exif?[kCGImagePropertyExifOffsetTime] as? String) ?? resolvedOffsets?.standard
        addField("Offset Time", offsetTimeVal)

        // 8. Offset Time Original
        let offsetTimeOrigVal = (exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String) ?? resolvedOffsets?.original
        addField("Offset Time Original", offsetTimeOrigVal)

        // 9. Offset Time Digitized
        let offsetTimeDigVal = (exif?[kCGImagePropertyExifOffsetTimeDigitized] as? String) ?? resolvedOffsets?.digitized
        addField("Offset Time Digitized", offsetTimeDigVal)

        // 10. GPS Latitude Ref
        addField("GPS Latitude Ref", gps?[kCGImagePropertyGPSLatitudeRef] as? String)

        // 11. GPS Latitude
        if let lat = rawGPS?.lat ?? (gps?[kCGImagePropertyGPSLatitude] as? Double) {
            addField("GPS Latitude", String(format: "%.15g", lat))
        }

        // 12. GPS Longitude Ref
        addField("GPS Longitude Ref", gps?[kCGImagePropertyGPSLongitudeRef] as? String)

        // 13. GPS Longitude
        if let lon = rawGPS?.lon ?? (gps?[kCGImagePropertyGPSLongitude] as? Double) {
            addField("GPS Longitude", String(format: "%.15g", lon))
        }

        // 14. GPS Altitude Ref
        if let altRef = gps?[kCGImagePropertyGPSAltitudeRef] {
            addField("GPS Altitude Ref", "\(altRef)")
        }

        // 15. GPS Altitude
        if let alt = rawGPS?.alt ?? (gps?[kCGImagePropertyGPSAltitude] as? Double) {
            addField("GPS Altitude", String(format: "%.10g", alt))
        }

        // 16. GPS Date Stamp
        addField("GPS Date Stamp", gps?[kCGImagePropertyGPSDateStamp] as? String)

        // 17. GPS Time Stamp
        addField("GPS Time Stamp", rawGPS?.timeStamp ?? (gps?[kCGImagePropertyGPSTimeStamp] as? String))

        return fields
    }

    /// Extract raw QuickTime date & GPS fields from a video file
    func extractVideoRawDateAndGPSFields(
        fileURL: URL,
        creationDateStr: String?,
        locationISO6709Str: String?
    ) -> [ExifRawField] {
        var fields: [ExifRawField] = []

        func addField(_ label: String, _ value: String?) {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            fields.append(ExifRawField(label: label, value: v))
        }

        let mvhdDates = parseQuickTimeMvhdDates(from: fileURL)

        // 3. Modify Date (QuickTime MovieHeader modification time)
        addField("Modify Date", mvhdDates.modifyDate)

        // 4. Create Date (QuickTime MovieHeader creation time)
        addField("Create Date", mvhdDates.createDate)

        // 6. Creation Date (QuickTime Keys CreationDate)
        if let creationDateStr = creationDateStr {
            addField("Creation Date", formatISOToExifDate(creationDateStr))
        }

        // 18. GPS Coordinates (QuickTime Keys Location ISO6709)
        if let locationISO6709Str = locationISO6709Str {
            addField("GPS Coordinates", formatISO6709ToRawCoordinates(locationISO6709Str))
        }

        return fields
    }

    /// Extract genuine XMP date tags (`xmp:CreateDate`, `xmp:ModifyDate`, `photoshop:DateCreated`) across all `<rdf:RDF>` blocks
    private func extractRawXMPTags(from data: Data) -> [String: String] {
        var result: [String: String] = [:]
        guard let rdfStartMarker = "<rdf:RDF".data(using: .utf8),
              let rdfEndMarker = "</rdf:RDF>".data(using: .utf8) else {
            return result
        }

        let keys = ["xmp:CreateDate", "xmp:ModifyDate", "photoshop:DateCreated"]
        var searchStart = data.startIndex

        while searchStart < data.endIndex,
              let startRange = data.range(of: rdfStartMarker, options: [], in: searchStart..<data.endIndex),
              let endRange = data.range(of: rdfEndMarker, options: [], in: startRange.lowerBound..<data.endIndex) {
            let xmpSlice = data[startRange.lowerBound..<endRange.upperBound]
            if let xmpStr = String(data: xmpSlice, encoding: .utf8) {
                for key in keys where result[key] == nil {
                    // Check element form: <key>value</key>
                    let openTag = "<\(key)>"
                    let closeTag = "</\(key)>"
                    if let r1 = xmpStr.range(of: openTag),
                       let r2 = xmpStr.range(of: closeTag, range: r1.upperBound..<xmpStr.endIndex) {
                        let val = String(xmpStr[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !val.isEmpty {
                            result[key] = val
                        }
                    } else if let r1 = xmpStr.range(of: "\(key)=\"") {
                        // Check attribute form: key="value"
                        if let r2 = xmpStr.range(of: "\"", range: r1.upperBound..<xmpStr.endIndex) {
                            let val = String(xmpStr[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !val.isEmpty {
                                result[key] = val
                            }
                        }
                    }
                }
            }
            searchStart = endRange.upperBound
        }

        return result
    }

    /// Locate TIFF header offsets in raw data (byte 0 for TIFF/DNG/RAW, or after "Exif\0\0" for JPEG/HEIF)
    private func findTIFFHeaderOffsets(in data: Data) -> [Int] {
        var offsets: [Int] = []
        if data.count >= 8 {
            let b0 = data[0]
            let b1 = data[1]
            let b2 = data[2]
            let b3 = data[3]
            if (b0 == 0x49 && b1 == 0x49 && b2 == 0x2A && b3 == 0x00) ||
               (b0 == 0x4D && b1 == 0x4D && b2 == 0x00 && b3 == 0x2A) {
                offsets.append(0)
            }
        }
        let exifMarker = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"
        var searchPos = data.startIndex
        let searchLimit = min(data.endIndex, data.startIndex + 262144)
        while searchPos < searchLimit,
              let r = data.range(of: exifMarker, options: [], in: searchPos..<searchLimit) {
            offsets.append(r.upperBound)
            searchPos = r.upperBound
        }
        return offsets
    }

    /// Extract raw EXIF OffsetTime tags (OffsetTimeOriginal 0x9011, OffsetTime 0x9010, OffsetTimeDigitized 0x9012)
    /// directly from the raw TIFF IFD structure. This is critical for DNG/RAW files where Apple's ImageIO
    /// parser completely omits timezone offset tags from {Exif}.
    private func parseRawExifOffsets(from data: Data) -> (original: String?, standard: String?, digitized: String?)? {
        for tiffStart in findTIFFHeaderOffsets(in: data) {
            guard tiffStart + 8 <= data.count else { continue }
            let isLittleEndian: Bool
            let b0 = data[tiffStart]
            let b1 = data[tiffStart + 1]
            if b0 == 0x49 && b1 == 0x49 {
                isLittleEndian = true
            } else if b0 == 0x4D && b1 == 0x4D {
                isLittleEndian = false
            } else {
                continue
            }

            func readU16(_ offset: Int) -> UInt16? {
                let pos = tiffStart + offset
                guard pos >= 0, pos + 2 <= data.count else { return nil }
                let x0 = UInt16(data[pos])
                let x1 = UInt16(data[pos + 1])
                return isLittleEndian ? (x0 | (x1 << 8)) : ((x0 << 8) | x1)
            }

            func readU32(_ offset: Int) -> UInt32? {
                let pos = tiffStart + offset
                guard pos >= 0, pos + 4 <= data.count else { return nil }
                let x0 = UInt32(data[pos])
                let x1 = UInt32(data[pos + 1])
                let x2 = UInt32(data[pos + 2])
                let x3 = UInt32(data[pos + 3])
                if isLittleEndian {
                    return x0 | (x1 << 8) | (x2 << 16) | (x3 << 24)
                } else {
                    return (x0 << 24) | (x1 << 16) | (x2 << 8) | x3
                }
            }

            func readAsciiString(valOffset: Int, count: Int) -> String? {
                guard count > 0 && count < 64 else { return nil }
                let strStart: Int
                if count <= 4 {
                    strStart = tiffStart + valOffset
                } else {
                    guard let offset = readU32(valOffset).map({ Int($0) }) else { return nil }
                    strStart = tiffStart + offset
                }
                guard strStart >= 0, strStart + count <= data.count else { return nil }
                let sub = data.subdata(in: strStart..<(strStart + count))
                guard let str = String(data: sub, encoding: .ascii) ?? String(data: sub, encoding: .utf8) else { return nil }
                let cleaned = str.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \t\r\n"))
                return cleaned.isEmpty ? nil : cleaned
            }

            guard readU16(2) == 0x002A,
                  let ifd0Offset = readU32(4).map({ Int($0) }),
                  let ifd0Count = readU16(ifd0Offset).map({ Int($0) }),
                  ifd0Count > 0 && ifd0Count < 1000 else {
                continue
            }

            var exifSubIFDOffset: Int?
            var origOffset: String?
            var stdOffset: String?
            var digOffset: String?

            func scanIFD(offset: Int, count: Int) {
                for i in 0..<count {
                    let entryOffset = offset + 2 + i * 12
                    guard let tag = readU16(entryOffset),
                          let type = readU16(entryOffset + 2),
                          let count = readU32(entryOffset + 4).map({ Int($0) }) else { break }

                    if tag == 0x8769 && type == 4 {
                        exifSubIFDOffset = readU32(entryOffset + 8).map { Int($0) }
                    } else if tag == 0x9011 && type == 2 {
                        origOffset = readAsciiString(valOffset: entryOffset + 8, count: count)
                    } else if tag == 0x9010 && type == 2 {
                        stdOffset = readAsciiString(valOffset: entryOffset + 8, count: count)
                    } else if tag == 0x9012 && type == 2 {
                        digOffset = readAsciiString(valOffset: entryOffset + 8, count: count)
                    }
                }
            }

            scanIFD(offset: ifd0Offset, count: ifd0Count)

            if let subOffset = exifSubIFDOffset,
               let subCount = readU16(subOffset).map({ Int($0) }),
               subCount > 0 && subCount < 1000 {
                scanIFD(offset: subOffset, count: subCount)
            }

            if origOffset != nil || stdOffset != nil || digOffset != nil {
                return (origOffset, stdOffset, digOffset)
            }
        }
        return nil
    }

    /// Parse unrounded rational values from the raw EXIF GPS IFD (tag 0x8825) if present
    private func parseRawGPSIFD(from data: Data) -> (lat: Double?, lon: Double?, alt: Double?, timeStamp: String?)? {
        for tiffStart in findTIFFHeaderOffsets(in: data) {
            guard tiffStart + 8 <= data.count else { continue }
            let isLittleEndian: Bool
            let b0 = data[tiffStart]
            let b1 = data[tiffStart + 1]
            if b0 == 0x49 && b1 == 0x49 {
                isLittleEndian = true
            } else if b0 == 0x4D && b1 == 0x4D {
                isLittleEndian = false
            } else {
                continue
            }

            func readU16(_ offset: Int) -> UInt16? {
                let pos = tiffStart + offset
                guard pos >= 0, pos + 2 <= data.count else { return nil }
                let b0 = UInt16(data[pos])
                let b1 = UInt16(data[pos + 1])
                return isLittleEndian ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
            }

            func readU32(_ offset: Int) -> UInt32? {
                let pos = tiffStart + offset
                guard pos >= 0, pos + 4 <= data.count else { return nil }
                let b0 = UInt32(data[pos])
                let b1 = UInt32(data[pos + 1])
                let b2 = UInt32(data[pos + 2])
                let b3 = UInt32(data[pos + 3])
                return isLittleEndian
                    ? (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
                    : ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            }

            guard readU16(2) == 0x002A,
                  let ifd0Offset = readU32(4).map({ Int($0) }),
                  let ifd0Count = readU16(ifd0Offset).map({ Int($0) }),
                  ifd0Count > 0 && ifd0Count < 500 else {
                continue
            }

            var gpsIFDOffset: Int?
            for i in 0..<ifd0Count {
                let entryOffset = ifd0Offset + 2 + i * 12
                guard let tag = readU16(entryOffset) else { break }
                if tag == 0x8825 {
                    gpsIFDOffset = readU32(entryOffset + 8).map { Int($0) }
                    break
                }
            }

            guard let gpsOffset = gpsIFDOffset,
                  let gpsCount = readU16(gpsOffset).map({ Int($0) }),
                  gpsCount > 0 && gpsCount < 200 else {
                continue
            }

            func readRational(_ offset: Int) -> Double? {
                guard let num = readU32(offset), let den = readU32(offset + 4), den != 0 else { return nil }
                return Double(num) / Double(den)
            }

            var lat: Double?
            var lon: Double?
            var alt: Double?
            var timeStamp: String?

            for i in 0..<gpsCount {
                let entryOffset = gpsOffset + 2 + i * 12
                guard let tag = readU16(entryOffset),
                      let type = readU16(entryOffset + 2),
                      let count = readU32(entryOffset + 4),
                      let valOffset = readU32(entryOffset + 8).map({ Int($0) }) else {
                    continue
                }

                // Type 5 = URATIONAL (two UInt32s: numerator, denominator)
                if type == 5 {
                    if tag == 0x0002 && count == 3 {
                        if let d = readRational(valOffset),
                           let m = readRational(valOffset + 8),
                           let s = readRational(valOffset + 16) {
                            lat = d + m / 60.0 + s / 3600.0
                        }
                    } else if tag == 0x0004 && count == 3 {
                        if let d = readRational(valOffset),
                           let m = readRational(valOffset + 8),
                           let s = readRational(valOffset + 16) {
                            lon = d + m / 60.0 + s / 3600.0
                        }
                    } else if tag == 0x0006 && count == 1 {
                        alt = readRational(valOffset)
                    } else if tag == 0x0007 && count == 3 {
                        if let h = readRational(valOffset),
                           let m = readRational(valOffset + 8),
                           let s = readRational(valOffset + 16) {
                            let hInt = Int(h)
                            let mInt = Int(m)
                            let sInt = Int(s)
                            if abs(s - Double(sInt)) < 1e-6 {
                                timeStamp = String(format: "%02d:%02d:%02d", hInt, mInt, sInt)
                            } else {
                                let secStr = String(format: "%06.3f", s)
                                    .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
                                    .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
                                timeStamp = String(format: "%02d:%02d:%@", hInt, mInt, secStr)
                            }
                        }
                    }
                }
            }

            if lat != nil || lon != nil || alt != nil || timeStamp != nil {
                return (lat, lon, alt, timeStamp)
            }
        }

        return nil
    }

    /// Parses an ISO-8601 QuickTime CreationDate string into a `Date`.
    nonisolated private func parseQuickTimeCreationDateString(_ creationStr: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        if let d = df.date(from: creationStr) {
            return d
        }
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return df.date(from: creationStr)
    }

    /// Reads the embedded QuickTime `CreationDate` from a video file's metadata atoms, if present.
    nonisolated private func parseQuickTimeEmbeddedCreationDate(from fileURL: URL) -> Date? {
        let avAsset = AVURLAsset(url: fileURL)
        for item in avAsset.metadata {
            let keyStr = (item.key as? String) ?? ""
            if keyStr == AVMetadataKey.quickTimeMetadataKeyCreationDate.rawValue ||
               keyStr == "com.apple.quicktime.creationdate" ||
               item.commonKey == .commonKeyCreationDate,
               let valStr = item.stringValue {
                return parseQuickTimeCreationDateString(valStr)
            }
        }
        return nil
    }

    /// Returns true if a video's QuickTime `mvhd` CreateDate or ModifyDate differs from `creationDate` by more than 5 minutes.
    nonisolated func isVideoMvhdDrifted(fileURL: URL, creationDate: Date?) -> Bool {
        guard let referenceDate = creationDate else { return false }
        let mvhd = parseQuickTimeMvhdDateObjects(from: fileURL)
        let threshold: TimeInterval = 5 * 60
        if let createDate = mvhd.createDate, abs(createDate.timeIntervalSince(referenceDate)) > threshold {
            return true
        }
        if let modifyDate = mvhd.modifyDate, abs(modifyDate.timeIntervalSince(referenceDate)) > threshold {
            return true
        }
        return false
    }

    /// Parse QuickTime MovieHeader (`mvhd`) creation and modification timestamps (UTC)
    private func parseQuickTimeMvhdDates(from fileURL: URL) -> (createDate: String?, modifyDate: String?) {
        let dates = parseQuickTimeMvhdDateObjects(from: fileURL)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return (
            dates.createDate.map { fmt.string(from: $0) },
            dates.modifyDate.map { fmt.string(from: $0) }
        )
    }

    /// Parse QuickTime MovieHeader (`mvhd`) creation and modification `Date` objects (UTC)
    nonisolated private func parseQuickTimeMvhdDateObjects(from fileURL: URL) -> (createDate: Date?, modifyDate: Date?) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return (nil, nil) }
        defer { try? handle.close() }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64) ?? 0
        guard fileSize >= 8 else { return (nil, nil) }

        func readData(at offset: UInt64, length: Int) -> Data? {
            guard offset + UInt64(length) <= fileSize else { return nil }
            do {
                try handle.seek(toOffset: offset)
                return try handle.read(upToCount: length)
            } catch {
                return nil
            }
        }

        func readU32BE(_ d: Data, _ offset: Int) -> UInt32 {
            (UInt32(d[offset]) << 24) | (UInt32(d[offset + 1]) << 16) | (UInt32(d[offset + 2]) << 8) | UInt32(d[offset + 3])
        }

        func readU64BE(_ d: Data, _ offset: Int) -> UInt64 {
            (UInt64(readU32BE(d, offset)) << 32) | UInt64(readU32BE(d, offset + 4))
        }

        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            guard let header = readData(at: offset, length: 16), header.count >= 8 else { break }
            var atomSize = UInt64(readU32BE(header, 0))
            let atomType = String(data: header.subdata(in: 4..<8), encoding: .ascii) ?? ""
            var headerSize: UInt64 = 8

            if atomSize == 1 {
                guard header.count >= 16 else { break }
                atomSize = readU64BE(header, 8)
                headerSize = 16
            } else if atomSize == 0 {
                atomSize = fileSize - offset
            }

            guard atomSize >= headerSize else { break }

            if atomType == "moov" {
                let moovEnd = min(offset + atomSize, fileSize)
                var subOffset = offset + headerSize
                while subOffset + 8 <= moovEnd {
                    guard let subHeader = readData(at: subOffset, length: 16), subHeader.count >= 8 else { break }
                    var subSize = UInt64(readU32BE(subHeader, 0))
                    let subType = String(data: subHeader.subdata(in: 4..<8), encoding: .ascii) ?? ""
                    var subHeaderSize: UInt64 = 8
                    if subSize == 1 {
                        guard subHeader.count >= 16 else { break }
                        subSize = readU64BE(subHeader, 8)
                        subHeaderSize = 16
                    } else if subSize == 0 {
                        subSize = moovEnd - subOffset
                    }
                    guard subSize >= subHeaderSize else { break }

                    if subType == "mvhd" {
                        guard let mvhdData = readData(at: subOffset + subHeaderSize, length: 24), mvhdData.count >= 12 else {
                            return (nil, nil)
                        }
                        let version = mvhdData[0]
                        let creationMac: UInt64
                        let modificationMac: UInt64
                        if version == 1 && mvhdData.count >= 20 {
                            creationMac = readU64BE(mvhdData, 4)
                            modificationMac = readU64BE(mvhdData, 12)
                        } else {
                            creationMac = UInt64(readU32BE(mvhdData, 4))
                            modificationMac = UInt64(readU32BE(mvhdData, 8))
                        }

                        let macEpochOffset: UInt64 = 2_082_844_800
                        let createDate: Date? = creationMac > macEpochOffset
                            ? Date(timeIntervalSince1970: TimeInterval(creationMac - macEpochOffset))
                            : nil
                        let modifyDate: Date? = modificationMac > macEpochOffset
                            ? Date(timeIntervalSince1970: TimeInterval(modificationMac - macEpochOffset))
                            : nil
                        return (createDate, modifyDate)
                    }
                    subOffset += subSize
                }
                break
            }
            offset += atomSize
        }

        return (nil, nil)
    }

    /// Convert ISO-8601 date string (`2024-03-17T13:04:11-0500` or `2024-08-18T13:22:16`) into ExifTool style (`2024:03:17 13:04:11-05:00` or `2024:08:18 13:22:16`)
    private func formatISOToExifDate(_ str: String) -> String {
        var s = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 10 {
            let chars = Array(s)
            if chars[4] == "-" && chars[7] == "-" {
                var modified = chars
                modified[4] = ":"
                modified[7] = ":"
                if modified.count > 10 && (modified[10] == "T" || modified[10] == "t") {
                    modified[10] = " "
                }
                s = String(modified)
            }
        }
        // Normalize trailing timezone offset like -0500 or +0800 to -05:00 or +08:00
        if let range = s.range(of: #"[+-]\d{4}$"#, options: .regularExpression) {
            let tz = s[range]
            let signAndHours = tz.prefix(3)
            let mins = tz.suffix(2)
            s.replaceSubrange(range, with: "\(signAndHours):\(mins)")
        }
        return s
    }

    /// Convert ISO-6709 location string (`+39.0569-094.5907+293.624/`) into space-separated raw coordinates (`39.0569 -94.5907 293.624`)
    private func formatISO6709ToRawCoordinates(_ iso6709: String) -> String? {
        let pattern = #"([+-]\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(iso6709.startIndex..<iso6709.endIndex, in: iso6709)
        let matches = regex.matches(in: iso6709, range: nsRange)
        guard matches.count >= 2 else { return nil }

        var parts: [String] = []
        for match in matches.prefix(3) {
            if let range = Range(match.range(at: 1), in: iso6709),
               let value = Double(iso6709[range]) {
                parts.append(String(format: "%.10g", value))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Folder Media Metadata Evaluation (Embedded Metadata Only)

    struct FolderEvaluatedMetadata {
        let embeddedDate: Date?
        let effectiveDate: Date?
        let timeZone: TimeZone
        let hasEmbeddedTimeZone: Bool
        let isDrifted: Bool
        let pixelWidth: Int
        let pixelHeight: Int
        let duration: TimeInterval?
        let location: CLLocation?
    }

    /// Evaluates embedded metadata from a CGImageSource (works with header-only Data or local URL).
    /// When no embedded timestamp is found, defaults to `fileModificationDate` and `fallbackTimeZone` with `hasEmbeddedTimeZone = false`.
    nonisolated func evaluateEmbeddedPhotoMetadata(
        from imageSource: CGImageSource,
        headerData: Data? = nil,
        fileModificationDate: Date?,
        fallbackTimeZone: TimeZone = .current
    ) -> FolderEvaluatedMetadata {
        let properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        let dims = Self.orientedPixelDimensions(
            from: properties,
            fallbackWidth: (exif?[kCGImagePropertyExifPixelXDimension] as? Int) ?? 0,
            fallbackHeight: (exif?[kCGImagePropertyExifPixelYDimension] as? Int) ?? 0
        )
        let pixelWidth = dims.width
        let pixelHeight = dims.height
        let location = parseGPSLocation(gpsDict: gps)

        var embeddedDateStr = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)

        var offsetTimeStr = (exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifOffsetTime] as? String)
            ?? (exif?[kCGImagePropertyExifOffsetTimeDigitized] as? String)

        if offsetTimeStr == nil, let headerData {
            let rawOffsets = parseRawExifOffsets(from: headerData)
            offsetTimeStr = rawOffsets?.original ?? rawOffsets?.standard ?? rawOffsets?.digitized
        }

        var exifTimeZone = parseTimezone(fromOffset: offsetTimeStr)
        var embeddedDate: Date? = nil

        if let str = embeddedDateStr {
            embeddedDate = parseExifDateString(str, in: exifTimeZone ?? fallbackTimeZone)
                ?? parseQuickTimeCreationDateString(str)
            if exifTimeZone == nil, let isoTZ = extractTimezoneFromISO8601(str) {
                exifTimeZone = isoTZ
            }
        }

        // Fallback to XMP metadata (e.g. PNG with ISO-8601 XMP chunk)
        if embeddedDate == nil, let cgMeta = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil) {
            let xmpPaths = ["exif:DateTimeOriginal", "xmp:CreateDate", "photoshop:DateCreated", "exif:DateTimeDigitized"]
            for path in xmpPaths {
                if let val = CGImageMetadataCopyStringValueWithPath(cgMeta, nil, path as CFString) as String?, !val.isEmpty {
                    embeddedDateStr = val
                    if let isoTZ = extractTimezoneFromISO8609OrISO8601Timezone(val) {
                        exifTimeZone = exifTimeZone ?? isoTZ
                    }
                    embeddedDate = parseQuickTimeCreationDateString(val)
                        ?? parseExifDateString(val, in: exifTimeZone ?? fallbackTimeZone)
                    if embeddedDate != nil { break }
                }
            }
        }

        let hasEmbeddedTimeZone = (embeddedDate != nil && exifTimeZone != nil)
        let effectiveTimeZone = hasEmbeddedTimeZone ? (exifTimeZone ?? fallbackTimeZone) : fallbackTimeZone
        let effectiveDate = embeddedDate ?? fileModificationDate ?? Date()

        return FolderEvaluatedMetadata(
            embeddedDate: embeddedDate,
            effectiveDate: effectiveDate,
            timeZone: effectiveTimeZone,
            hasEmbeddedTimeZone: hasEmbeddedTimeZone,
            isDrifted: false,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            duration: nil,
            location: location
        )
    }

    /// Evaluates embedded metadata from a video URL (or a minimal [ftyp][moov] temp file).
    func evaluateEmbeddedVideoMetadata(
        from fileURL: URL,
        fileModificationDate: Date?,
        fallbackTimeZone: TimeZone = .current
    ) async -> FolderEvaluatedMetadata {
        let avAsset = AVURLAsset(url: fileURL)
        var creationDateStr: String? = nil
        var locationStr: String? = nil

        if let commonMeta = try? await avAsset.load(.commonMetadata) {
            for item in commonMeta {
                if item.commonKey == .commonKeyCreationDate {
                    creationDateStr = try? await item.load(.stringValue)
                } else if item.commonKey == .commonKeyLocation {
                    locationStr = try? await item.load(.stringValue)
                }
            }
        }

        var width = 0
        var height = 0
        if let tracks = try? await avAsset.loadTracks(withMediaType: .video), let videoTrack = tracks.first {
            let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
            let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
            let transformed = naturalSize.applying(transform)
            width = Int(abs(transformed.width))
            height = Int(abs(transformed.height))
        }

        let cmDuration = (try? await avAsset.load(.duration)) ?? .zero
        let seconds = CMTimeGetSeconds(cmDuration)
        let duration: TimeInterval? = (seconds.isFinite && seconds > 0) ? seconds : nil
        let location = locationStr.flatMap { parseISO6709($0) }

        var embeddedDate: Date? = nil
        var videoTZ: TimeZone? = nil
        if let str = creationDateStr {
            videoTZ = extractTimezoneFromISO8609OrISO8601Timezone(str)
            embeddedDate = parseQuickTimeCreationDateString(str)
                ?? parseExifDateString(str, in: videoTZ ?? fallbackTimeZone)
        }

        let hasEmbeddedTimeZone = (embeddedDate != nil && videoTZ != nil)
        let effectiveTimeZone = hasEmbeddedTimeZone ? (videoTZ ?? fallbackTimeZone) : fallbackTimeZone
        let effectiveDate = embeddedDate ?? fileModificationDate ?? Date()

        let isDrifted = (embeddedDate != nil)
            ? isVideoMvhdDrifted(fileURL: fileURL, creationDate: embeddedDate)
            : false

        return FolderEvaluatedMetadata(
            embeddedDate: embeddedDate,
            effectiveDate: effectiveDate,
            timeZone: effectiveTimeZone,
            hasEmbeddedTimeZone: hasEmbeddedTimeZone,
            isDrifted: isDrifted,
            pixelWidth: width,
            pixelHeight: height,
            duration: duration,
            location: location
        )
    }

    /// Returns display-oriented pixel dimensions, swapping width and height for EXIF orientations 5...8.
    private nonisolated static func orientedPixelDimensions(
        from properties: [CFString: Any],
        fallbackWidth: Int,
        fallbackHeight: Int
    ) -> (width: Int, height: Int) {
        let rawWidth = (properties[kCGImagePropertyPixelWidth] as? Int) ?? fallbackWidth
        let rawHeight = (properties[kCGImagePropertyPixelHeight] as? Int) ?? fallbackHeight
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let orientation = (properties[kCGImagePropertyOrientation] as? Int)
            ?? (tiff?[kCGImagePropertyTIFFOrientation] as? Int)
            ?? 1
        if (5...8).contains(orientation) {
            return (rawHeight, rawWidth)
        }
        return (rawWidth, rawHeight)
    }

    private nonisolated func extractTimezoneFromISO8601(_ str: String) -> TimeZone? {
        extractTimezoneFromISO8609OrISO8601Timezone(str)
    }

    private nonisolated func extractTimezoneFromISO8609OrISO8601Timezone(_ str: String) -> TimeZone? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("Z") || trimmed.hasSuffix("z") {
            return TimeZone(secondsFromGMT: 0)
        }
        let pattern = #"([+-]\d{2}:?\d{2})$"#
        if let range = trimmed.range(of: pattern, options: .regularExpression) {
            return parseTimezone(fromOffset: String(trimmed[range]))
        }
        return nil
    }

    /// Parses full PhotoExifMetadata for a folder photo item (for PhotoDetailView)
    func parseFolderPhotoMetadata(from imageSource: CGImageSource, rawData: Data?, item: PhotoItem) -> PhotoExifMetadata {
        let properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        let eval = evaluateEmbeddedPhotoMetadata(
            from: imageSource,
            headerData: rawData,
            fileModificationDate: item.fileModificationDate,
            fallbackTimeZone: item.isDateAdjusted ? .current : item.timeZone
        )

        let effectiveDate = item.isDateAdjusted ? item.creationDate : (eval.embeddedDate ?? item.creationDate ?? eval.effectiveDate)
        let effectiveTZ = item.isDateAdjusted ? item.timeZone : (eval.hasEmbeddedTimeZone ? eval.timeZone : item.timeZone)
        let effectiveLocation = item.isGPSAdjusted ? item.location : (eval.location ?? item.location)
        let byteCount = rawData.map { Int64($0.count) } ?? item.fileSize ?? 0
        let ext = item.fileExtension.isEmpty ? "IMAGE" : item.fileExtension

        let rawFields: [ExifRawField]
        if let rawData {
            rawFields = extractImageRawDateAndGPSFields(from: rawData)
        } else {
            rawFields = []
        }

        let lensModel = exif?[kCGImagePropertyExifLensModel] as? String
        let focalLength = exif?[kCGImagePropertyExifFocalLength] as? Double
        let focalLength35mm = exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
        let aperture = exif?[kCGImagePropertyExifFNumber] as? Double
        let shutterSpeed = exif?[kCGImagePropertyExifExposureTime] as? Double
        let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int]
        let exposureBias = exif?[kCGImagePropertyExifExposureBiasValue] as? Double
        let flashValue = exif?[kCGImagePropertyExifFlash] as? Int
        let colorSpaceVal = exif?[kCGImagePropertyExifColorSpace] as? Int
        let colorSpaceStr: String? = colorSpaceVal.map { $0 == 1 ? "sRGB" : ($0 == 65535 ? "Uncalibrated" : "ColorSpace (\($0))") }

        return PhotoExifMetadata(
            filename: item.filename,
            fileSizeString: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file),
            fileByteCount: byteCount,
            fileTypeString: ext,
            pixelWidth: eval.pixelWidth > 0 ? eval.pixelWidth : item.pixelWidth,
            pixelHeight: eval.pixelHeight > 0 ? eval.pixelHeight : item.pixelHeight,
            creationDate: effectiveDate,
            embeddedDate: eval.embeddedDate,
            isDateAdjusted: item.isDateAdjusted,
            isEdited: false,
            timeZone: effectiveTZ,
            originalTimeZone: eval.timeZone,
            offsetTimeString: DateFormatters.exifTimezoneOffset(for: effectiveDate ?? Date(), in: effectiveTZ),
            cameraMake: tiff?[kCGImagePropertyTIFFMake] as? String,
            cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String,
            lensModel: lensModel,
            focalLength: focalLength,
            focalLength35mm: focalLength35mm,
            aperture: aperture,
            shutterSpeed: shutterSpeed,
            iso: isoArray?.first,
            exposureBias: exposureBias,
            flashFired: flashValue.map { ($0 & 0x01) != 0 },
            colorSpace: colorSpaceStr,
            isSavedFromOtherApps: false,
            appOriginHint: nil,
            location: effectiveLocation,
            originalLocation: eval.location,
            isGPSAdjusted: item.isGPSAdjusted,
            altitude: effectiveLocation?.altitude,
            heading: nil,
            speed: nil,
            isVideo: false,
            duration: nil,
            fps: nil,
            codec: nil,
            hasEmbeddedTimeZone: eval.hasEmbeddedTimeZone,
            isDrifted: false,
            rawDateAndGPSFields: rawFields
        )
    }

    /// Parses full PhotoExifMetadata for a folder video item (for PhotoDetailView)
    func parseFolderVideoMetadata(from fileURL: URL, item: PhotoItem, knownByteCount: Int64? = nil) async -> PhotoExifMetadata {
        let avAsset = AVURLAsset(url: fileURL)
        let eval = await evaluateEmbeddedVideoMetadata(
            from: fileURL,
            fileModificationDate: item.fileModificationDate,
            fallbackTimeZone: item.isDateAdjusted ? .current : item.timeZone
        )

        var make: String? = nil
        var model: String? = nil
        var creationDateStr: String? = nil
        var locationStr: String? = nil
        if let commonMeta = try? await avAsset.load(.commonMetadata) {
            for m in commonMeta {
                if m.commonKey == .commonKeyMake { make = try? await m.load(.stringValue) }
                else if m.commonKey == .commonKeyModel { model = try? await m.load(.stringValue) }
                else if m.commonKey == .commonKeyCreationDate { creationDateStr = try? await m.load(.stringValue) }
                else if m.commonKey == .commonKeyLocation { locationStr = try? await m.load(.stringValue) }
            }
        }

        var fps: Double? = nil
        var codec: String? = nil
        if let tracks = try? await avAsset.loadTracks(withMediaType: .video), let videoTrack = tracks.first {
            let rate = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
            if rate > 0 { fps = Double(rate) }
            if let desc = (try? await videoTrack.load(.formatDescriptions))?.first {
                let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                let fourCC = withUnsafeBytes(of: mediaSubType.bigEndian) { String(bytes: $0, encoding: .ascii) }
                codec = fourCC?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let effectiveDate = item.isDateAdjusted ? item.creationDate : (eval.embeddedDate ?? item.creationDate ?? eval.effectiveDate)
        let effectiveTZ = item.isDateAdjusted ? item.timeZone : (eval.hasEmbeddedTimeZone ? eval.timeZone : item.timeZone)
        let effectiveLocation = item.isGPSAdjusted ? item.location : (eval.location ?? item.location)
        let fileOnDiskSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
        let byteCount = knownByteCount ?? fileOnDiskSize ?? item.fileSize ?? 0
        let ext = item.fileExtension.isEmpty ? "VIDEO" : item.fileExtension
        let rawFields = extractVideoRawDateAndGPSFields(
            fileURL: fileURL,
            creationDateStr: creationDateStr,
            locationISO6709Str: locationStr
        )

        return PhotoExifMetadata(
            filename: item.filename,
            fileSizeString: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file),
            fileByteCount: byteCount,
            fileTypeString: ext,
            pixelWidth: eval.pixelWidth > 0 ? eval.pixelWidth : item.pixelWidth,
            pixelHeight: eval.pixelHeight > 0 ? eval.pixelHeight : item.pixelHeight,
            creationDate: effectiveDate,
            embeddedDate: eval.embeddedDate,
            isDateAdjusted: item.isDateAdjusted,
            isEdited: false,
            timeZone: effectiveTZ,
            originalTimeZone: eval.timeZone,
            offsetTimeString: DateFormatters.exifTimezoneOffset(for: effectiveDate ?? Date(), in: effectiveTZ),
            cameraMake: make,
            cameraModel: model,
            lensModel: nil,
            focalLength: nil,
            focalLength35mm: nil,
            aperture: nil,
            shutterSpeed: nil,
            iso: nil,
            exposureBias: nil,
            flashFired: nil,
            colorSpace: nil,
            isSavedFromOtherApps: false,
            appOriginHint: nil,
            location: effectiveLocation,
            originalLocation: eval.location,
            isGPSAdjusted: item.isGPSAdjusted,
            altitude: effectiveLocation?.altitude,
            heading: nil,
            speed: nil,
            isVideo: true,
            duration: eval.duration ?? item.duration,
            fps: fps,
            codec: codec,
            hasEmbeddedTimeZone: eval.hasEmbeddedTimeZone,
            isDrifted: eval.isDrifted,
            rawDateAndGPSFields: rawFields
        )
    }

    /// Fallback video metadata constructed from cached/listed PhotoItem fields when container atoms aren't parseable over byte ranges.
    func fallbackFolderVideoMetadata(for item: PhotoItem) -> PhotoExifMetadata {
        let byteCount = item.fileSize ?? 0
        let ext = item.fileExtension.isEmpty ? "VIDEO" : item.fileExtension
        let effectiveDate = item.creationDate ?? item.embeddedDate ?? item.fileModificationDate
        return PhotoExifMetadata(
            filename: item.filename,
            fileSizeString: byteCount > 0 ? ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) : "Unknown",
            fileByteCount: byteCount,
            fileTypeString: ext,
            pixelWidth: item.pixelWidth,
            pixelHeight: item.pixelHeight,
            creationDate: effectiveDate,
            embeddedDate: item.embeddedDate,
            isDateAdjusted: item.isDateAdjusted,
            isEdited: false,
            timeZone: item.timeZone,
            originalTimeZone: item.timeZone,
            offsetTimeString: effectiveDate.map { DateFormatters.exifTimezoneOffset(for: $0, in: item.timeZone) },
            cameraMake: nil,
            cameraModel: nil,
            lensModel: nil,
            focalLength: nil,
            focalLength35mm: nil,
            aperture: nil,
            shutterSpeed: nil,
            iso: nil,
            exposureBias: nil,
            flashFired: nil,
            colorSpace: nil,
            isSavedFromOtherApps: false,
            appOriginHint: nil,
            location: item.location,
            originalLocation: item.location,
            isGPSAdjusted: item.isGPSAdjusted,
            altitude: item.location?.altitude,
            heading: nil,
            speed: nil,
            isVideo: true,
            duration: item.duration,
            fps: nil,
            codec: nil,
            hasEmbeddedTimeZone: item.hasEmbeddedTimeZone,
            isDrifted: item.isDrifted,
            rawDateAndGPSFields: []
        )
    }
}
