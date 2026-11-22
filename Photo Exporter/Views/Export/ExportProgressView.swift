//
//  ExportProgressView.swift
//  Photo Exporter
//

import SwiftUI

struct ExportProgressView: View {
    @Binding var progress: ExportProgress
    var mediaSource: MediaSource = .photoLibrary
    let onCancel: () -> Void
    var onDismiss: (() -> Void)? = nil
    var onResume: (() -> Void)? = nil
    let onFinish: () -> Void
    var onRetryFailed: (([PhotoItem]) -> Void)? = nil

    @State private var isCopied: Bool = false
    @State private var isShowingDoneConfirmation: Bool = false

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
                        .font(.system(size: 48))
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
                }

                // Currently Uploading File Info Card (Thumbnail, File Name, and Time)
                if progress.isExporting, let current = progress.currentItem {
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
                if progress.isExporting {
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
                        title: progress.isApplyInPlace ? "Updated" : "Exported",
                        value: "\(progress.successCount)",
                        icon: "checkmark",
                        color: .green
                    )
                    if progress.failureCount > 0 {
                        statCard(
                            title: "Failed",
                            value: "\(progress.failureCount)",
                            icon: "xmark",
                            color: .red
                        )
                    }
                }
                .padding(.horizontal, 24)

                // Error list if any occurred
                if !progress.errorMessages.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Issues encountered (\(progress.errorMessages.count)):")
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
                                        .foregroundColor(.red)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: progress.isExporting ? 100 : 240)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                    }
                    .padding(.horizontal, 24)
                }

                Spacer()

                // Action Buttons
                VStack(spacing: 12) {
                    if progress.isExporting {
                        Button(role: .cancel, action: onCancel) {
                            Text(progress.isApplyInPlace ? "Cancel Apply" : "Cancel Export")
                                .font(.headline)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red.opacity(0.12))
                                .cornerRadius(12)
                        }
                    } else {
                        let hasResume = (progress.isCancelled || progress.isInterrupted) && onResume != nil
                        let hasRetry = !progress.isCancelled && !progress.isInterrupted && !progress.failedItems.isEmpty && onRetryFailed != nil
                        let hasRecoveryOption = hasResume || hasRetry

                        if hasResume, let onResume = onResume {
                            let remaining = max(0, progress.totalCount - progress.successCount)
                            let resumeLabel = progress.isApplyInPlace ? "Resume Apply" : "Resume Upload"
                            Button(action: onResume) {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 15, weight: .bold))
                                    Text("\(resumeLabel)\(remaining > 0 ? " (\(remaining) Remaining)" : "")")
                                        .font(.headline)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .cornerRadius(12)
                            }
                        }

                        if hasRetry, let onRetry = onRetryFailed {
                            let retryNoun = progress.isApplyInPlace
                                ? (progress.failedItems.count == 1 ? "Update" : "Updates")
                                : (progress.failedItems.count == 1 ? "Upload" : "Uploads")
                            Button(action: { onRetry(progress.failedItems) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 15, weight: .bold))
                                    Text("Retry \(progress.failedItems.count) Failed \(retryNoun)")
                                        .font(.headline)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.orange)
                                .cornerRadius(12)
                            }
                        }

                        Button {
                            if hasRecoveryOption {
                                isShowingDoneConfirmation = true
                            } else {
                                onFinish()
                            }
                        } label: {
                            Text("Done")
                                .font(.headline)
                                .foregroundColor(hasRecoveryOption ? .primary : .white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(hasRecoveryOption ? Color(.secondarySystemBackground) : Color.blue)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .navigationTitle(progress.isApplyInPlace ? "Apply Changes" : "Media Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Dismiss") {
                        if let onDismiss {
                            onDismiss()
                        } else {
                            onFinish()
                        }
                    }
                    .font(.body)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .alert(progress.isApplyInPlace ? "Finish Apply?" : "Finish Export?", isPresented: $isShowingDoneConfirmation) {
            Button("Finish Anyway", role: .destructive) {
                onFinish()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if (progress.isCancelled || progress.isInterrupted) && onResume != nil {
                Text(progress.isApplyInPlace
                    ? "There are still remaining items that have not been updated. Finishing now will discard the resume option."
                    : "There are still remaining items that have not been exported. Finishing now will discard the resume option.")
            } else {
                Text("There are \(progress.failedItems.count) failed \(progress.failedItems.count == 1 ? "item" : "items") you can still retry. Finishing now will discard the retry option.")
            }
        }
    }

    private var statusIconName: String {
        if progress.isCancelled || progress.isInterrupted || progress.hasErrors {
            return "exclamationmark.triangle.fill"
        } else if progress.isCompleted {
            return "checkmark.circle.fill"
        } else {
            return "square.and.arrow.up.circle.fill"
        }
    }

    private var statusColor: Color {
        if progress.isCancelled || progress.isInterrupted || progress.hasErrors {
            return .orange
        } else if progress.isCompleted {
            return .green
        } else {
            return .blue
        }
    }

    private var titleText: String {
        if progress.isApplyInPlace {
            if progress.isInterrupted {
                return "Apply Paused"
            } else if progress.isCancelled {
                return "Apply Cancelled"
            } else if progress.isCompleted {
                if progress.hasErrors {
                    return progress.successCount == 0 ? "Apply Failed" : "Apply Completed with Errors"
                } else {
                    return "Changes Applied"
                }
            } else {
                return "Applying Changes"
            }
        }

        if progress.isInterrupted {
            return "Export Paused"
        } else if progress.isCancelled {
            return "Export Cancelled"
        } else if progress.isCompleted {
            if progress.hasErrors {
                return progress.successCount == 0 ? "Export Failed" : "Export Completed with Errors"
            } else {
                return "Export Completed"
            }
        } else {
            return "Exporting Media"
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundColor(color)

            Text(value)
                .font(.headline.weight(.bold))
                .foregroundColor(color)

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
