//
//  ZoomableImageView.swift
//  Photo Exporter
//

import SwiftUI

struct ZoomableImageView: View {
    let image: UIImage
    var isZoomed: Binding<Bool>? = nil
    var onSwipeLeft: (() -> Void)? = nil
    var onSwipeRight: (() -> Void)? = nil
    var onPinchToExitFullScreen: (() -> Void)? = nil

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var pinchBaseScale: CGFloat? = nil
    @State private var didTriggerPinchExit: Bool = false
    @State private var suppressSwipeUntil: Date = .distantPast

    var body: some View {
        GeometryReader { geometry in
            let containerSize = geometry.size
            let fitMetrics = calculateFitMetrics(containerSize: containerSize)

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            if pinchBaseScale == nil {
                                pinchBaseScale = scale
                                didTriggerPinchExit = false
                            }
                            let delta = lastScale > 0 ? (value / lastScale) : 1.0
                            lastScale = value
                            let canPinchExit = onPinchToExitFullScreen != nil && (pinchBaseScale ?? scale) <= 1.01
                            let minScale: CGFloat = canPinchExit ? 0.78 : 1.0
                            let newScale = min(max(scale * delta, minScale), 8.0)
                            scale = newScale
                            isZoomed?.wrappedValue = (newScale > 1.01)

                            if canPinchExit && !didTriggerPinchExit && newScale <= 0.84 {
                                didTriggerPinchExit = true
                                suppressSwipeUntil = Date().addingTimeInterval(0.25)
                                onPinchToExitFullScreen?()
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                                    scale = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                    isZoomed?.wrappedValue = false
                                }
                            }

                            // Clamp offset to ensure no black border is exposed
                            let bounds = maxOffsets(for: max(scale, 1.0), metrics: fitMetrics, containerSize: containerSize)
                            offset = clampOffset(offset, bounds: bounds)
                        }
                        .onEnded { _ in
                            let canPinchExit = onPinchToExitFullScreen != nil && (pinchBaseScale ?? scale) <= 1.01
                            let shouldExit = canPinchExit && !didTriggerPinchExit && scale <= 0.90
                            lastScale = 1.0
                            pinchBaseScale = nil
                            didTriggerPinchExit = false
                            suppressSwipeUntil = Date().addingTimeInterval(0.2)

                            if shouldExit {
                                onPinchToExitFullScreen?()
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                                    scale = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                    isZoomed?.wrappedValue = false
                                }
                            } else if scale <= 1.01 {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    scale = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                    isZoomed?.wrappedValue = false
                                }
                            } else {
                                isZoomed?.wrappedValue = true
                                let bounds = maxOffsets(for: scale, metrics: fitMetrics, containerSize: containerSize)
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    offset = clampOffset(offset, bounds: bounds)
                                    lastOffset = offset
                                }
                            }
                        }
                        .simultaneously(
                            with: DragGesture(minimumDistance: 15)
                                .onChanged { value in
                                    guard scale > 1.01 else { return }
                                    let rawX = lastOffset.width + value.translation.width
                                    let rawY = lastOffset.height + value.translation.height
                                    let bounds = maxOffsets(for: scale, metrics: fitMetrics, containerSize: containerSize)

                                    // Apply strict clamping so the photo edges never reveal black background
                                    let clampedX = min(max(rawX, -bounds.maxX), bounds.maxX)
                                    let clampedY = min(max(rawY, -bounds.maxY), bounds.maxY)

                                    offset = CGSize(width: clampedX, height: clampedY)
                                }
                                .onEnded { value in
                                    if scale > 1.01 {
                                        let bounds = maxOffsets(for: scale, metrics: fitMetrics, containerSize: containerSize)
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            offset = clampOffset(offset, bounds: bounds)
                                            lastOffset = offset
                                        }
                                    } else {
                                        guard pinchBaseScale == nil && Date() >= suppressSwipeUntil else { return }
                                        let horizontal = value.translation.width
                                        let vertical = value.translation.height
                                        let predicted = value.predictedEndTranslation.width
                                        if abs(horizontal) > abs(vertical) {
                                            if horizontal < -25 || predicted < -70 {
                                                onSwipeLeft?()
                                            } else if horizontal > 25 || predicted > 70 {
                                                onSwipeRight?()
                                            }
                                        }
                                    }
                                }
                        )
                )
                .onTapGesture(count: 2, coordinateSpace: .local) { tapLocation in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        if scale > 1.01 {
                            scale = 1.0
                            offset = .zero
                            lastOffset = .zero
                            isZoomed?.wrappedValue = false
                        } else {
                            // Zoom to original size / 1:1 pixel scale, or at least 2.5x to fill frame
                            let originalSizeScale = fitMetrics.originalPixelScale
                            let targetScale = min(max(originalSizeScale, 2.5), 6.0)
                            scale = targetScale
                            isZoomed?.wrappedValue = true

                            // Center on clicked area
                            let centerX = containerSize.width / 2.0
                            let centerY = containerSize.height / 2.0
                            let targetOffsetX = (centerX - tapLocation.x) * targetScale
                            let targetOffsetY = (centerY - tapLocation.y) * targetScale

                            // Clamp offset strictly to avoid black border exposure
                            let bounds = maxOffsets(for: targetScale, metrics: fitMetrics, containerSize: containerSize)
                            let clamped = clampOffset(CGSize(width: targetOffsetX, height: targetOffsetY), bounds: bounds)

                            offset = clamped
                            lastOffset = clamped
                        }
                    }
                }
                .onChange(of: image) { _ in
                    scale = 1.0
                    lastScale = 1.0
                    offset = .zero
                    lastOffset = .zero
                    pinchBaseScale = nil
                    didTriggerPinchExit = false
                    isZoomed?.wrappedValue = false
                }
        }
        .clipped()
    }

    // MARK: - Clamping & Dimension Helpers

    private struct FitMetrics {
        let fittedWidth: CGFloat
        let fittedHeight: CGFloat
        let originalPixelScale: CGFloat
    }

    private func calculateFitMetrics(containerSize: CGSize) -> FitMetrics {
        guard image.size.width > 0, image.size.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return FitMetrics(fittedWidth: containerSize.width, fittedHeight: containerSize.height, originalPixelScale: 2.5)
        }

        let widthRatio = containerSize.width / image.size.width
        let heightRatio = containerSize.height / image.size.height
        let fitRatio = min(widthRatio, heightRatio)

        let fittedW = image.size.width * fitRatio
        let fittedH = image.size.height * fitRatio

        // Original 100% pixel scale in relation to container fitted points
        let pixelScale = fitRatio > 0 ? (1.0 / fitRatio) : 2.5

        return FitMetrics(fittedWidth: fittedW, fittedHeight: fittedH, originalPixelScale: pixelScale)
    }

    private func maxOffsets(for currentScale: CGFloat, metrics: FitMetrics, containerSize: CGSize) -> (maxX: CGFloat, maxY: CGFloat) {
        let currentWidth = metrics.fittedWidth * currentScale
        let currentHeight = metrics.fittedHeight * currentScale

        let maxX = currentWidth > containerSize.width ? (currentWidth - containerSize.width) / 2.0 : 0
        let maxY = currentHeight > containerSize.height ? (currentHeight - containerSize.height) / 2.0 : 0

        return (maxX, maxY)
    }

    private func clampOffset(_ targetOffset: CGSize, bounds: (maxX: CGFloat, maxY: CGFloat)) -> CGSize {
        let clampedX = min(max(targetOffset.width, -bounds.maxX), bounds.maxX)
        let clampedY = min(max(targetOffset.height, -bounds.maxY), bounds.maxY)
        return CGSize(width: clampedX, height: clampedY)
    }
}
