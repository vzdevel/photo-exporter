//
//  FloatingProgressBannerView.swift
//  Photo Exporter
//

import SwiftUI

struct FloatingProgressBannerView: View {
    let status: PhotoListViewModel.ProgressStatus
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 12) {
                if status.hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 15, weight: .bold))
                } else if status.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 15, weight: .bold))
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                        .scaleEffect(0.8)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(status.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)

                        Spacer(minLength: 8)

                        Text(status.countText)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                    }

                    // Mini progress track
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 3.5)

                            Capsule()
                                .fill(status.hasError ? Color.orange : (status.isComplete ? Color.green : Color.blue))
                                .frame(
                                    width: max(0, min(geo.size.width * CGFloat(status.progress), geo.size.width)),
                                    height: 3.5
                                )
                                .animation(.linear(duration: 0.2), value: status.progress)
                        }
                    }
                    .frame(height: 3.5)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 300)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}
