//
//  ApplyChangesSummarySheet.swift
//  Photo Exporter
//

import SwiftUI

/// Summary sheet presented when applying inferred timezones / adjustments in place to files in a folder.
struct ApplyChangesSummarySheet: View {
    let items: [PhotoItem]
    let mediaSource: MediaSource
    let onConfirmApply: ([PhotoItem]) -> Void
    let onCancel: () -> Void

    private var itemsToApply: [PhotoItem] {
        items.filter { $0.needsInPlaceApply }.sortedChronologicallyAscending()
    }

    private var ignoredCount: Int {
        max(0, items.count - itemsToApply.count)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        // Target folder header
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(mediaSource.iconColor.opacity(0.15))
                                    .frame(width: 40, height: 40)

                                AppSourceIconView(
                                    iconName: mediaSource.iconName,
                                    isAssetImage: mediaSource.isAssetIcon,
                                    size: mediaSource.isAssetIcon ? 24 : 18,
                                    color: mediaSource.iconColor
                                )
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(mediaSource.navigationTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)

                                Text(mediaSource.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        if itemsToApply.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(.green)

                                Text("No Changes to Apply")
                                    .font(.headline)

                                Text("None of the selected files have an inferred timezone, pending adjustments, or drifted video timestamps.")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                            .padding(.horizontal, 16)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("\(itemsToApply.count) \(itemsToApply.count == 1 ? "File" : "Files") to Update In Place")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundColor(.primary)
                                    Spacer()
                                }

                                if ignoredCount > 0 {
                                    Text("\(ignoredCount) unmodified \(ignoredCount == 1 ? "file" : "files") with no inferred timezone or adjustments will be skipped.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Divider()

                                LazyVStack(spacing: 10) {
                                    ForEach(itemsToApply) { item in
                                        HStack(spacing: 12) {
                                            DeviceThumbnailView(
                                                asset: item.asset,
                                                isVideo: item.isVideo,
                                                size: 40,
                                                item: item,
                                                mediaSource: mediaSource
                                            )

                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(item.filename)
                                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                                    .foregroundColor(.primary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)

                                                HStack(spacing: 4) {
                                                    if item.isDateAdjusted {
                                                        StatusBadgeView(type: .adjustedDate, compact: false)
                                                    }
                                                    if item.isGPSAdjusted {
                                                        StatusBadgeView(type: .adjustedGPS, compact: false)
                                                    }
                                                    if item.isRotationAdjusted {
                                                        StatusBadgeView(type: .adjustedRotation, compact: false)
                                                    }
                                                    if item.hasInferredTimeZone {
                                                        StatusBadgeView(type: .inferred, compact: false)
                                                    }
                                                    if item.isVideo && item.isDrifted {
                                                        StatusBadgeView(type: .drifted, compact: false)
                                                    }
                                                }
                                            }

                                            Spacer()
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(16)
                }

                // Bottom Action Bar
                VStack(spacing: 10) {
                    if !itemsToApply.isEmpty {
                        Button {
                            onConfirmApply(itemsToApply)
                        } label: {
                            Text("Apply Changes (\(itemsToApply.count))")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    } else {
                        Button(action: onCancel) {
                            Text("Done")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.systemGroupedBackground))
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Apply Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

