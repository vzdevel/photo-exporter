//
//  PhotoRowView.swift
//  Photo Exporter
//

import SwiftUI
import Photos

struct PhotoRowView: View {
    let item: PhotoItem
    let isSelected: Bool
    let isSelectionMode: Bool
    let isRangeSelectionMode: Bool
    let isLastSelected: Bool
    var mediaSource: MediaSource = .photoLibrary
    let onSelectRangeToHere: () -> Void

    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    @State private var thumbnail: UIImage? = nil
    @State private var imageRequestID: PHImageRequestID? = nil
    @State private var folderThumbTask: Task<Void, Never>? = nil
    @State private var loadedModDate: Date? = nil
    @State private var loadedHasAdjustments: Bool = false
    @State private var loadedPendingRotation: Int = 0

    var body: some View {
        rowContent
            .contextMenu {
                if isSelectionMode {
                    Button {
                        onSelectRangeToHere()
                    } label: {
                        Label("Select Range to Here", systemImage: "arrow.up.and.down.and.sparkles")
                    }
                }
            }
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            // Selection indicator
            ZStack {
                Circle()
                    .strokeBorder(isSelected ? Color.blue : Color.gray.opacity(0.4), lineWidth: 2)
                    .frame(width: 22, height: 22)

                if isSelected {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 22, height: 22)

                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 24, height: 24)
            .opacity(isSelectionMode ? 1 : 0)
            .scaleEffect(isSelectionMode ? 1.0 : 0.4)
            .frame(width: isSelectionMode ? 24 : 0)
            .clipped()
            .padding(.trailing, isSelectionMode ? 12 : 0)
            .animation(.easeInOut(duration: 0.2), value: isSelected)

            // Thumbnail
            ZStack {
                if let thumb = thumbnail {
                    let pendingSteps = mediaSource.isFolder ? ExifMetadataService.clockwiseSteps(forDegrees: item.pendingRotationDegrees) : 0
                    let displayedThumb = pendingSteps != 0
                        ? ExifMetadataService.rotateUIImage(thumb, clockwiseSteps: pendingSteps)
                        : thumb
                    Image(uiImage: displayedThumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 52, height: 52)
                        .overlay(
                            Image(systemName: item.isVideo ? "video" : "photo")
                                .foregroundColor(.secondary)
                        )
                }

                // Video indicator overlay
                if item.isVideo {
                    VStack {
                        Spacer()
                        HStack(spacing: 2) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                            if let dur = item.formattedDuration {
                                Text(dur)
                                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                            }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.65))
                        .clipShape(Capsule())
                        .padding(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 52, height: 52)
                }

                // Small badge for edited photo on thumbnail
                if item.isEdited {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(3)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                                .padding(2)
                        }
                    }
                    .frame(width: 52, height: 52)
                }
            }
            .padding(.trailing, 10)

            // Info Column
            VStack(alignment: .leading, spacing: 2) {
                // File name & extension
                HStack(alignment: .center, spacing: 6) {
                    Text(item.filename)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isLastSelected && isSelectionMode && isRangeSelectionMode {
                        Text("Active")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.indigo)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.indigo.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                // File Size, Date, Time & Short UTC Offset
                HStack(spacing: 4) {
                    if let size = item.fileSize, size > 0 {
                        Text(Self.fileSizeFormatter.string(fromByteCount: size))
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if let _ = item.creationDate {
                        Text(item.formattedDate)
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text(item.formattedTime)
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        if !item.formattedShortUTCOffset.isEmpty {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            Text(item.formattedShortUTCOffset)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("No Date Recorded")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                // Badges row
                HStack(spacing: 4) {
                    if item.isDateAdjusted {
                        StatusBadgeView(type: .adjustedDate)
                    }
                    if item.isGPSAdjusted {
                        StatusBadgeView(type: .adjustedGPS)
                    }
                    if item.isRotationAdjusted {
                        StatusBadgeView(type: .adjustedRotation)
                    }
                    if item.isEdited {
                        StatusBadgeView(type: .edited)
                    }
                    if item.hasInferredTimeZone {
                        StatusBadgeView(type: .inferred)
                    }
                    if item.isDrifted {
                        StatusBadgeView(type: .drifted)
                    }
                    if item.isSavedFromOtherApps {
                        StatusBadgeView(type: .otherApp)
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(.tertiaryLabel))
                .opacity(isSelectionMode ? 0 : 1)
                .scaleEffect(isSelectionMode ? 0.5 : 1.0)
                .frame(width: isSelectionMode ? 0 : nil)
                .clipped()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isSelectionMode)
        .onAppear {
            loadThumbnail()
        }
        .onDisappear {
            cancelThumbnailLoad()
        }
        .onChange(of: item.modificationDate) { _, _ in
            loadThumbnail()
        }
        .onChange(of: item.id) { _, _ in
            loadThumbnail(forceReload: true)
        }
        .onChange(of: item.remoteThumbnailLink) { _, _ in
            loadThumbnail(forceReload: true)
        }
        .onChange(of: item.asset?.hasAdjustments ?? false) { _, _ in
            loadThumbnail()
        }
        .onChange(of: item.pendingRotationDegrees) { _, newDegrees in
            if mediaSource.isFolder && loadedPendingRotation != 0 && newDegrees == 0 {
                loadThumbnail(forceReload: true)
            }
            loadedPendingRotation = newDegrees
        }
        .onReceive(NotificationCenter.default.publisher(for: .folderThumbnailInvalidated)) { notification in
            guard mediaSource.isFolder,
                  let invalidatedID = notification.object as? String,
                  invalidatedID == item.id else { return }
            loadThumbnail(forceReload: true)
        }
    }

    private func loadThumbnail(forceReload: Bool = false) {
        let modDate = item.modificationDate
        let hasAdj = item.asset?.hasAdjustments ?? false
        let isFolderCacheMissing = mediaSource.isFolder && FolderMediaService.shared.cachedThumbnail(for: item, in: mediaSource) == nil
        guard forceReload || thumbnail == nil || loadedModDate != modDate || loadedHasAdjustments != hasAdj || isFolderCacheMissing else { return }

        cancelThumbnailLoad()
        loadedModDate = modDate
        loadedHasAdjustments = hasAdj
        loadedPendingRotation = item.pendingRotationDegrees

        if let asset = item.asset {
            imageRequestID = PhotoLibraryService.shared.requestThumbnail(for: asset) { img in
                self.thumbnail = img
            }
        } else if mediaSource.isFolder {
            if let cached = FolderMediaService.shared.cachedThumbnail(for: item, in: mediaSource) {
                self.thumbnail = cached
            } else {
                folderThumbTask = Task {
                    let img = await FolderMediaService.shared.loadThumbnail(for: item, in: mediaSource)
                    if !Task.isCancelled {
                        await MainActor.run {
                            self.thumbnail = img
                        }
                    }
                }
            }
        }
    }

    private func cancelThumbnailLoad() {
        if let id = imageRequestID {
            PhotoLibraryService.shared.imageManager.cancelImageRequest(id)
            imageRequestID = nil
        }
        folderThumbTask?.cancel()
        folderThumbTask = nil
    }
}
