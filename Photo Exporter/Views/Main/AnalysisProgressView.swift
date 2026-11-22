//
//  AnalysisProgressView.swift
//  Photo Exporter
//
//  Created by Antigravity on 2026-11-10.
//

import SwiftUI
import Photos

struct AnalysisProgressView: View {
    @Binding var progress: AnalysisProgress
    var mediaSource: MediaSource = .photoLibrary
    let onDismiss: () -> Void
    var onRetryFailed: (([PhotoItem]) -> Void)? = nil

    @State private var isCopied: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Icon / Status animation
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 96, height: 96)

                    Image(systemName: statusIconName)
                        .font(.system(size: 46))
                        .foregroundColor(statusColor)
                }

                // Title & Subtitle
                VStack(spacing: 8) {
                    Text(titleText)
                        .font(.title2.weight(.bold))

                    Text(progress.statusSummary)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Currently Analyzing Item Card (Thumbnail, File Name, and Time)
                if progress.isAnalyzing, let current = progress.currentItem {
                    HStack(spacing: 12) {
                        DeviceThumbnailView(asset: current.asset, isVideo: current.isVideo, size: 44, item: current, mediaSource: mediaSource)
                            .id(current.id)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(current.filename)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            HStack(spacing: 4) {
                                if let _ = current.creationDate ?? current.embeddedDate {
                                    Text(current.formattedDate)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    Text("•")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    Text(current.formattedTime)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    if !current.formattedShortUTCOffset.isEmpty {
                                        Text("•")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)

                                        Text(current.formattedShortUTCOffset)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                if let size = current.effectiveFileSize, size > 0 {
                                    Text("•")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Spacer()
                    }
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 24)
                }

                // Progress Bar & Percentage
                if progress.isAnalyzing {
                    VStack(spacing: 8) {
                        ProgressView(value: progress.fractionCompleted)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                            .scaleEffect(x: 1, y: 1.5, anchor: .center)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        HStack {
                            if !progress.currentFilename.isEmpty {
                                Text(progress.currentFilename)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(progress.percentageString)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                // Statistics Cards
                HStack(spacing: 16) {
                    statCard(
                        title: "Total",
                        value: "\(progress.totalCount)",
                        icon: "photo.stack",
                        color: .primary
                    )
                    statCard(
                        title: "Analyzed",
                        value: "\(progress.processedCount)",
                        icon: "checkmark",
                        color: .green
                    )
                    if !progress.errorMessages.isEmpty || !progress.failedItems.isEmpty {
                        let count = max(progress.errorMessages.count, progress.failedItems.count)
                        statCard(
                            title: "Pending Retry",
                            value: "\(count)",
                            icon: "arrow.triangle.2.circlepath",
                            color: .orange
                        )
                    } else {
                        statCard(
                            title: "Remaining",
                            value: "\(max(0, progress.totalCount - progress.processedCount))",
                            icon: "hourglass",
                            color: .secondary
                        )
                    }
                }
                .padding(.horizontal, 24)

                // Stay on screen reminder while analyzing
                if progress.isAnalyzing {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.blue)

                        Text("Please keep the app open while analyzing photo metadata.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 24)
                }

                // Error / retry list if any occurred
                if !progress.errorMessages.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Retrying items (\(progress.errorMessages.count)):")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)

                            Spacer()

                            Button {
                                let allErrors = progress.errorMessages.joined(separator: "\n")
                                UIPasteboard.general.string = allErrors
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isCopied = true
                                }
                                Task {
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isCopied = false
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(isCopied ? "Copied" : "Copy All")
                                        .font(.caption2.weight(.medium))
                                }
                                .foregroundColor(isCopied ? .green : .accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(.tertiarySystemFill))
                                .cornerRadius(6)
                            }
                        }

                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(progress.errorMessages.enumerated()), id: \.offset) { _, msg in
                                    Text("• \(msg)")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: progress.isAnalyzing ? 90 : 180)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                    }
                    .padding(.horizontal, 24)
                }

                Spacer()

                // Action Buttons
                VStack(spacing: 12) {
                    if progress.isAnalyzing {
                        Button {
                            onDismiss()
                        } label: {
                            Text("Run in Background")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(.secondarySystemFill))
                                .foregroundColor(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    } else {
                        if !progress.failedItems.isEmpty, let onRetry = onRetryFailed {
                            Button(action: {
                                onRetry(progress.failedItems)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 15, weight: .bold))
                                    Text("Retry \(progress.failedItems.count) Failed \(progress.failedItems.count == 1 ? "Item" : "Items")")
                                        .font(.headline)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }

                        Button(action: onDismiss) {
                            Text("Done")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(progress.failedItems.isEmpty ? Color.blue : Color(.secondarySystemFill))
                                .foregroundColor(progress.failedItems.isEmpty ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .navigationTitle("Photo Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Dismiss") {
                        onDismiss()
                    }
                    .font(.body)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var statusIconName: String {
        if progress.isFinished {
            let failCount = max(progress.errorMessages.count, progress.failedItems.count)
            return failCount == 0 ? "checkmark" : "exclamationmark.triangle"
        }
        return "sparkle.magnifyingglass"
    }

    private var statusColor: Color {
        if progress.isFinished {
            let failCount = max(progress.errorMessages.count, progress.failedItems.count)
            return failCount == 0 ? .green : .orange
        }
        return .blue
    }

    private var titleText: String {
        if progress.isFinished {
            let failCount = max(progress.errorMessages.count, progress.failedItems.count)
            return failCount == 0 ? "Analysis Complete" : "Analysis Finished"
        }
        return "Analyzing Photos"
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(color)

            Text(value)
                .font(.title3.weight(.bold))
                .foregroundColor(.primary)

            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }
}

