//
//  SelectionToolbarView.swift
//  Photo Exporter
//

import SwiftUI

struct SelectionToolbarView: View {
    let selectedCount: Int
    let totalVisibleCount: Int
    var isExportDisabled: Bool = false
    var showsApplyAction: Bool = false
    @Binding var isRangeSelectionMode: Bool
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onBatchEditDateTime: () -> Void
    let onDelete: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Secondary row: Quick selection shortcuts
            HStack(spacing: 8) {
                // Range mode toggle button
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isRangeSelectionMode.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isRangeSelectionMode ? "arrow.up.and.down.circle.fill" : "arrow.up.and.down.circle")
                            .font(.system(size: 13, weight: .bold))
                        Text(isRangeSelectionMode ? "Range Mode: ON" : "Range Mode")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isRangeSelectionMode ? Color.indigo : Color.clear)
                    .background(.ultraThinMaterial)
                    .foregroundColor(isRangeSelectionMode ? .white : .primary)
                    .clipShape(Capsule())
                    .shadow(color: Color.black.opacity(0.08), radius: 4, y: 2)
                }

                Spacer()

                if selectedCount < totalVisibleCount {
                    Button(action: onSelectAll) {
                        Text("Select All")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .shadow(color: Color.black.opacity(0.08), radius: 4, y: 2)
                    }
                }

                if selectedCount > 0 {
                    Button(action: onDeselectAll) {
                        Text("Deselect")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .shadow(color: Color.black.opacity(0.08), radius: 4, y: 2)
                    }
                }
            }
            .padding(.horizontal, 16)

            // Primary action bar
            HStack(spacing: 10) {
                // Counter badge
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 15))

                    Text("\(selectedCount) Selected")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                }
                .padding(.leading, 4)

                Spacer()

                // Batch Date & Time button (icon only)
                Button(action: onBatchEditDateTime) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(Color.indigo.opacity(selectedCount > 0 ? 0.15 : 0.08))
                        .foregroundColor(selectedCount > 0 ? .indigo : .secondary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .disabled(selectedCount == 0)
                .accessibilityLabel("Edit Date and Time")

                // Delete button (icon only)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(Color.red.opacity(selectedCount > 0 ? 0.15 : 0.08))
                        .foregroundColor(selectedCount > 0 ? .red : .secondary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .disabled(selectedCount == 0)
                .accessibilityLabel("Delete")

                // Export / Apply button
                let canExport = selectedCount > 0 && !isExportDisabled
                Button(action: onExport) {
                    HStack(spacing: 6) {
                        Image(systemName: showsApplyAction ? "wand.and.stars" : "square.and.arrow.up")
                            .font(.system(size: 14, weight: .bold))
                        Text(showsApplyAction ? "Apply" : "Export")
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(canExport ? Color.blue : Color.gray.opacity(0.3))
                    .foregroundColor(canExport ? .white : Color.white.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: canExport ? Color.blue.opacity(0.3) : .clear, radius: 6, y: 3)
                }
                .disabled(!canExport)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.black.opacity(0.1), radius: 10, y: 4)
            .padding(.horizontal, 12)
        }
        .opacity(0.96)
        .padding(.bottom, 6)
    }
}
