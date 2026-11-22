//
//  ExifMetadataCardView.swift
//  Photo Exporter
//

import SwiftUI

struct ExifMetadataCardView: View {
    let metadata: PhotoExifMetadata
    var onAdjustDate: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            DateTimeCardView(metadata: metadata, onAdjustDate: onAdjustDate)
            if metadata.hasCameraOrLensData {
                CameraLensCardView(metadata: metadata)
            }
            FileInfoCardView(metadata: metadata)
            if !metadata.rawDateAndGPSFields.isEmpty {
                ExifDateGPSCardView(metadata: metadata)
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Date & Time Card

struct DateTimeCardView: View {
    let metadata: PhotoExifMetadata
    var onAdjustDate: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.blue)

                Text("Date & Time")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Spacer()

                if metadata.isDateAdjusted {
                    StatusBadgeView(type: .adjustedDate)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metadata.isDateAdjusted ? "Adjusted Date" : "Current Date")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metadata.formattedAdjustedDateTime)
                            .font(.system(.subheadline, design: .rounded))
                    }
                    Spacer()
                    if let onAdjustDate = onAdjustDate {
                        Button(action: onAdjustDate) {
                            HStack(spacing: 3) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Adjust")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Timezone")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(metadata.timeZone.identifier.replacingOccurrences(of: "_", with: " "))
                            .font(.subheadline)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        if metadata.hasInferredTimeZone {
                            Text("Inferred")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.indigo)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.indigo.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        if let offset = metadata.offsetTimeString {
                            Text("Offset: \(offset)")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.tertiarySystemFill))
                                .cornerRadius(4)
                        }
                    }
                }

                if let originalDate = metadata.formattedOriginalDateTime, metadata.isDateAdjusted {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Original Embedded EXIF Date")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(originalDate)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

// MARK: - Camera & Lens Card

struct CameraLensCardView: View {
    let metadata: PhotoExifMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.blue)

                Text("Camera & Lens")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Spacer()

                if metadata.isSavedFromOtherApps {
                    StatusBadgeView(type: .otherApp)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metadata.cameraString)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))

                        if let lens = metadata.lensString {
                            Text(lens)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }

                if !metadata.isVideo {
                    Divider()

                    // Exposure stats
                    if metadata.hasExposureData {
                        Text(metadata.exposureString)
                            .font(.system(.footnote, design: .monospaced, weight: .medium))
                            .foregroundColor(.primary)
                    } else {
                        Text(metadata.exposureString)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    if let flash = metadata.flashFired {
                        HStack(spacing: 4) {
                            Image(systemName: flash ? "bolt.fill" : "bolt.slash.fill")
                                .font(.caption)
                                .foregroundColor(flash ? .yellow : .secondary)
                            Text(flash ? "Flash Fired" : "No Flash")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

// MARK: - File Info Card

struct FileInfoCardView: View {
    let metadata: PhotoExifMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.blue)

                Text("Media Information")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Spacer()

                HStack(spacing: 6) {
                    if metadata.isSavedFromOtherApps && !metadata.hasCameraOrLensData {
                        StatusBadgeView(type: .otherApp)
                    }
                    if metadata.isRotationAdjusted {
                        StatusBadgeView(type: .adjustedRotation)
                    }
                    if metadata.isEdited {
                        StatusBadgeView(type: .edited)
                    }
                }
            }

            VStack(spacing: 8) {
                let originalName = metadata.originalFilename ?? metadata.filename
                filenameRow(value: originalName)
                if let cameraRollName = metadata.cameraRollFilename,
                   !cameraRollName.isEmpty,
                   cameraRollName.caseInsensitiveCompare(originalName) != .orderedSame {
                    Divider()
                    infoRow(label: "Camera Roll File Name", value: cameraRollName)
                }
                Divider()
                infoRow(label: "Dimensions", value: metadata.megapixelsString)
                Divider()
                infoRow(label: "File Size", value: metadata.fileSizeString)
                Divider()
                infoRow(label: "Format", value: metadata.fileTypeString)
                if metadata.isVideo {
                    if let dur = metadata.duration {
                        let totalSecs = Int(round(dur))
                        let mins = totalSecs / 60
                        let secs = totalSecs % 60
                        Divider()
                        infoRow(label: "Duration", value: String(format: "%d:%02d (%.1fs)", mins, secs, dur))
                    }
                    if let fps = metadata.fps {
                        Divider()
                        infoRow(label: "Frame Rate", value: String(format: "%.1f fps", fps))
                    }
                    if let codec = metadata.codec {
                        Divider()
                        infoRow(label: "Codec", value: codec)
                    }
                } else if let colorSpace = metadata.colorSpace {
                    Divider()
                    infoRow(label: "Color Space", value: colorSpace)
                }

                if metadata.isEdited {
                    Divider()
                    editsRow
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var editsRow: some View {
        let editColor = PhotoFilter.edited.color

        return HStack(alignment: .firstTextBaseline) {
            Text("Edits Applied")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer(minLength: 12)

            if !metadata.appliedEdits.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        ForEach(metadata.appliedEdits, id: \.self) { edit in
                            Text(edit)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(editColor.opacity(0.12))
                                .foregroundColor(editColor)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(editColor.opacity(0.25), lineWidth: 0.8)
                                )
                        }
                    }

                    Text(metadata.appliedEdits.joined(separator: ", "))
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundColor(editColor)
                        .multilineTextAlignment(.trailing)
                }
            } else {
                Text("Edited")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundColor(.primary)
            }
        }
    }

    private func filenameRow(value: String) -> some View {
        HStack {
            Text("File Name")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - EXIF Date & GPS Card

struct ExifDateGPSCardView: View {
    let metadata: PhotoExifMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.blue)

                Text("Raw EXIF Date & GPS")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Spacer()

                if metadata.isDrifted {
                    StatusBadgeView(type: .drifted)
                }
            }

            VStack(spacing: 8) {
                ForEach(Array(metadata.rawDateAndGPSFields.enumerated()), id: \.element.id) { index, field in
                    if index > 0 {
                        Divider()
                    }
                    infoRow(label: field.label, value: field.value)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
