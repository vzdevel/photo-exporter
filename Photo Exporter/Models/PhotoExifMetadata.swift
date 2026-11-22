//
//  PhotoExifMetadata.swift
//  Photo Exporter
//

import Foundation
import CoreLocation
import ImageIO

struct ExifRawField: Equatable, Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

struct PhotoExifMetadata: Equatable {
    // Basic File Properties
    var filename: String
    var originalFilename: String? = nil
    var cameraRollFilename: String? = nil
    var fileSizeString: String
    var fileByteCount: Int64
    var fileTypeString: String
    var pixelWidth: Int
    var pixelHeight: Int

    // Date & Time
    var creationDate: Date?
    var embeddedDate: Date?
    var isDateAdjusted: Bool
    var isEdited: Bool = false
    var appliedEdits: [String] = []
    var pendingRotationDegrees: Int = 0
    var timeZone: TimeZone
    var originalTimeZone: TimeZone? = nil
    var offsetTimeString: String?

    // Camera & Lens
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var focalLength: Double?
    var focalLength35mm: Int?
    var aperture: Double?
    var shutterSpeed: Double?
    var iso: Int?
    var exposureBias: Double?
    var flashFired: Bool?
    var colorSpace: String?

    // Origin classification
    var isSavedFromOtherApps: Bool
    var appOriginHint: String?

    // GPS Location
    var location: CLLocation?
    var originalLocation: CLLocation? = nil
    var isGPSAdjusted: Bool = false
    var altitude: Double?
    var heading: Double?
    var speed: Double?

    // Video Specific Properties
    var isVideo: Bool = false
    var duration: TimeInterval? = nil
    var fps: Double? = nil
    var codec: String? = nil

    // Timezone classification
    var hasEmbeddedTimeZone: Bool = false

    // Video QuickTime container date drift (> 5 minutes from CreationDate)
    var isDrifted: Bool = false

    // Raw EXIF / QuickTime Date & GPS fields
    var rawDateAndGPSFields: [ExifRawField] = []

    /// True if either date/time/timezone or GPS location was adjusted
    var isAdjusted: Bool {
        isDateAdjusted || isGPSAdjusted || isRotationAdjusted
    }

    /// True when folder media has an unapplied pending rotation (90°, 180°, or 270°)
    var isRotationAdjusted: Bool {
        ((pendingRotationDegrees % 360) + 360) % 360 != 0
    }

    /// True if timezone is inferred (no embedded timezone and no adjusted date, time, or timezone)
    var hasInferredTimeZone: Bool {
        !isDateAdjusted && !hasEmbeddedTimeZone
    }

    /// True if there is any camera, lens, or exposure metadata available
    var hasCameraOrLensData: Bool {
        let hasMake = cameraMake?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasModel = cameraModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasLens = lensModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasFocal = focalLength != nil
        let hasAperture = aperture != nil
        let hasSpeed = shutterSpeed != nil
        let hasIso = iso != nil
        let hasBias = exposureBias != nil && abs(exposureBias!) > 0.01
        let hasFlash = flashFired != nil

        return hasMake || hasModel || hasLens || hasFocal || hasAperture || hasSpeed || hasIso || hasBias || hasFlash
    }

    var hasExposureData: Bool {
        exposureString != "No Exposure Data"
    }

    /// Comma-separated list of applied edit descriptions
    var appliedEditsString: String {
        appliedEdits.joined(separator: ", ")
    }

    // Formatted Computed Properties
    var megapixelsString: String {
        guard pixelWidth > 0 && pixelHeight > 0 else { return "Unknown" }
        let mp = Double(pixelWidth * pixelHeight) / 1_000_000.0
        return String(format: "%.1f MP (%d × %d)", mp, pixelWidth, pixelHeight)
    }

    var cameraString: String {
        if let make = cameraMake, let model = cameraModel {
            if model.lowercased().hasPrefix(make.lowercased()) {
                return model
            }
            return "\(make) \(model)"
        }
        return cameraModel ?? cameraMake ?? "Unknown Camera"
    }

    var lensString: String? {
        lensModel
    }

    var exposureString: String {
        var components: [String] = []

        if let focal = focalLength {
            if let f35 = focalLength35mm {
                components.append(String(format: "%.0fmm (%dmm eq)", focal, f35))
            } else {
                components.append(String(format: "%.0fmm", focal))
            }
        }

        if let fNumber = aperture {
            components.append(String(format: "ƒ/%.1f", fNumber))
        }

        if let speed = shutterSpeed {
            if speed >= 1.0 {
                components.append(String(format: "%.1fs", speed))
            } else if speed > 0 {
                let denom = Int(round(1.0 / speed))
                components.append("1/\(denom)s")
            }
        }

        if let isoVal = iso {
            components.append("ISO \(isoVal)")
        }

        if let ev = exposureBias, abs(ev) > 0.01 {
            components.append(String(format: "%+.1f EV", ev))
        }

        return components.isEmpty ? "No Exposure Data" : components.joined(separator: " • ")
    }

    var formattedAdjustedDateTime: String {
        guard let date = creationDate else { return "No Date & Time" }
        return DateFormatters.dateTimeString(for: date, in: timeZone)
    }

    var formattedOriginalDateTime: String? {
        guard let date = embeddedDate else { return nil }
        let tz = originalTimeZone ?? timeZone
        return DateFormatters.fullTimestampString(for: date, in: tz)
    }

    static var empty: PhotoExifMetadata {
        PhotoExifMetadata(
            filename: "",
            fileSizeString: "0 KB",
            fileByteCount: 0,
            fileTypeString: "Unknown",
            pixelWidth: 0,
            pixelHeight: 0,
            creationDate: nil,
            embeddedDate: nil,
            isDateAdjusted: false,
            isEdited: false,
            appliedEdits: [],
            timeZone: .current,
            offsetTimeString: nil,
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
            location: nil,
            originalLocation: nil,
            isGPSAdjusted: false,
            altitude: nil,
            heading: nil,
            speed: nil,
            isVideo: false,
            duration: nil,
            fps: nil,
            codec: nil
        )
    }
}
