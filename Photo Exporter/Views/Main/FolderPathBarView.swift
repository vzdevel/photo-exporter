//
//  FolderPathBarView.swift
//  Photo Exporter
//

import SwiftUI
import UIKit

private struct FolderPathSegmentFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private final class WeakScrollViewBox {
    weak var scrollView: UIScrollView?
}

private final class ScrollViewFinderHostView: UIView {
    var onResolve: ((UIScrollView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveIfPossible()
    }

    func resolveIfPossible() {
        var current = superview
        while let candidate = current {
            if let scrollView = candidate as? UIScrollView {
                onResolve?(scrollView)
                return
            }
            current = candidate.superview
        }
    }
}

private struct PathScrollViewFinder: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> ScrollViewFinderHostView {
        let view = ScrollViewFinderHostView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onResolve = onResolve
        DispatchQueue.main.async {
            view.resolveIfPossible()
        }
        return view
    }

    func updateUIView(_ uiView: ScrollViewFinderHostView, context: Context) {
        uiView.onResolve = onResolve
        DispatchQueue.main.async {
            uiView.resolveIfPossible()
        }
    }
}

/// Horizontal scrollable breadcrumb path bar displayed above FilterBarView for folder sources.
struct FolderPathBarView: View {
    let segments: [FolderPathSegment]
    let activeCount: Int
    let revealRequest: PathBarRevealRequest?
    let onSelectSegment: (Int) -> Void

    @State private var scrollBox = WeakScrollViewBox()
    @State private var contentWidth: CGFloat = 0
    @State private var segmentFrames: [String: CGRect] = [:]
    @State private var lastHandledRevealNonce: Int = 0
    @State private var revealTask: Task<Void, Never>? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    let isActive = index < activeCount
                    let isCurrent = index == activeCount - 1

                    HStack(spacing: 4) {
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                                .opacity(isActive ? 0.8 : 0.35)
                        }

                        Button {
                            onSelectSegment(index)
                        } label: {
                            HStack(spacing: 5) {
                                if index == 0 {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 12))
                                }
                                Text(segment.name)
                                    .font(.system(size: 14, weight: isCurrent ? .semibold : .medium, design: .rounded))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundColor(segmentTextColor(isActive: isActive, isCurrent: isCurrent))
                            .background(segmentBackgroundColor(isActive: isActive, isCurrent: isCurrent))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .opacity(isActive ? 1.0 : 0.45)
                        }
                        .buttonStyle(.plain)
                        .background(
                            GeometryReader { segGeo in
                                Color.clear.preference(
                                    key: FolderPathSegmentFramePreferenceKey.self,
                                    value: [segment.id: segGeo.frame(in: .named("FolderPathContent"))]
                                )
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .coordinateSpace(name: "FolderPathContent")
            .background(
                GeometryReader { contentGeo in
                    Color.clear
                        .onAppear {
                            contentWidth = contentGeo.size.width
                            scheduleRevealCheck()
                        }
                        .onChange(of: contentGeo.size.width) { _, newWidth in
                            contentWidth = newWidth
                            scheduleRevealCheck()
                        }
                }
            )
            .background(
                PathScrollViewFinder { sv in
                    if scrollBox.scrollView !== sv {
                        scrollBox.scrollView = sv
                        scheduleRevealCheck()
                    }
                }
            )
        }
        .frame(height: 40)
        .onPreferenceChange(FolderPathSegmentFramePreferenceKey.self) { frames in
            segmentFrames = frames
            scheduleRevealCheck()
        }
        .onAppear {
            scheduleRevealCheck()
        }
        .onChange(of: revealRequest) { _, _ in
            scheduleRevealCheck()
        }
        .onDisappear {
            revealTask?.cancel()
        }
    }

    private func segmentTextColor(isActive: Bool, isCurrent: Bool) -> Color {
        if isCurrent {
            return .accentColor
        }
        return isActive ? .primary : .secondary
    }

    private func segmentBackgroundColor(isActive: Bool, isCurrent: Bool) -> Color {
        if isCurrent {
            return Color.accentColor.opacity(0.14)
        }
        return isActive ? Color(.secondarySystemBackground).opacity(0.75) : Color(.secondarySystemBackground).opacity(0.4)
    }

    private func scheduleRevealCheck() {
        guard let request = revealRequest, request.nonce != lastHandledRevealNonce else {
            return
        }
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            for attempt in 0..<10 {
                guard !Task.isCancelled else { return }
                let delayNs: UInt64 = attempt == 0 ? 30_000_000 : 25_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled else { return }
                if fulfillPendingRevealIfPossible() {
                    return
                }
            }
        }
    }

    @discardableResult
    private func fulfillPendingRevealIfPossible() -> Bool {
        guard let request = revealRequest,
              request.nonce != lastHandledRevealNonce,
              let sv = scrollBox.scrollView,
              let rect = segmentFrames[request.segmentID],
              rect.width > 0 else {
            return false
        }

        let visibleWidth = sv.bounds.width
        guard visibleWidth > 0 else { return false }

        // Wait for UIScrollView to commit the updated contentSize covering the new segment
        guard sv.contentSize.width + 1 >= rect.maxX else {
            return false
        }

        lastHandledRevealNonce = request.nonce

        let trailingPadding: CGFloat = 16
        let expectedContentWidth = max(sv.contentSize.width, max(contentWidth, rect.maxX + trailingPadding))
        let currentOffsetX = sv.contentOffset.x
        let maxOffsetX = max(0, expectedContentWidth - visibleWidth)

        if rect.maxX > currentOffsetX + visibleWidth - 8 {
            let targetX = min(maxOffsetX, max(0, rect.maxX + trailingPadding - visibleWidth))
            if abs(targetX - currentOffsetX) > 0.5 {
                sv.setContentOffset(CGPoint(x: targetX, y: sv.contentOffset.y), animated: true)
            }
        } else if rect.minX < currentOffsetX + 8 {
            let targetX = max(0, rect.minX - 16)
            if abs(targetX - currentOffsetX) > 0.5 {
                sv.setContentOffset(CGPoint(x: targetX, y: sv.contentOffset.y), animated: true)
            }
        }
        return true
    }
}

/// List row displaying a subfolder entry in the folder media list view.
struct FolderRowView: View {
    let folder: FolderListEntry

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.12))
                .frame(width: 60, height: 60)
                .overlay(
                    Image(systemName: "folder.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.blue)
                )
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let modDate = folder.modificationDate {
                    HStack(spacing: 4) {
                        Text(DateFormatters.mediumDateString(for: modDate, in: .current))
                            .font(.footnote)
                            .foregroundColor(.secondary)

                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text(DateFormatters.mediumTimeString(for: modDate, in: .current))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Folder")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .contentShape(Rectangle())
    }
}
