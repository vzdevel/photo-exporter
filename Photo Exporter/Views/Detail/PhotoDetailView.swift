//
//  PhotoDetailView.swift
//  Photo Exporter
//

import SwiftUI
import Photos
import AVKit

private struct DetailInlineMediaFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 1 && next.height > 1 {
            value = next
        }
    }
}

final class DetailPlayerHostingBox {
    var playerViewController: AVPlayerViewController?
    var currentPlayer: AVPlayer?
}

struct PhotoDetailView: View {
    @StateObject private var viewModel: PhotoDetailViewModel
    @ObservedObject var listViewModel: PhotoListViewModel
    @Environment(\.dismiss) private var dismiss
    var mediaSource: MediaSource = .photoLibrary
    var isExportDisabled: Bool = false
    var onDateAdjusted: ((String, Date, TimeZone, Bool) -> Void)? = nil
    var onMetadataRefreshed: ((String, PhotoExifMetadata) -> Void)? = nil
    var onFilenameChanged: ((String, String) -> Void)? = nil
    var onFolderItemUpdated: ((String, PhotoItem) -> Void)? = nil
    var onDeleted: ((String) -> Void)? = nil

    @State private var items: [PhotoItem]
    @State private var currentIndex: Int = 0
    @State private var isMediaZoomed: Bool = false
    @State private var isTransitioning: Bool = false
    @State private var slideOffset: CGFloat = 0
    @State private var isFullScreen: Bool = false
    @State private var isFullScreenOverlayMounted: Bool = false
    @State private var isFullScreenTransitionActive: Bool = false
    @State private var inlineMediaGlobalFrame: CGRect = .zero
    @State private var fullScreenTransitionGeneration: Int = 0
    @State private var hasAppeared: Bool = false
    @State private var isFullScreenButtonVisible: Bool = false
    @State private var fullScreenButtonHideTask: Task<Void, Never>? = nil
    @State private var playerHostingBox = DetailPlayerHostingBox()

    @State private var isShowingRenameAlert: Bool = false
    @State private var editedFilename: String = ""

    init(
        item: PhotoItem,
        items: [PhotoItem] = [],
        listViewModel: PhotoListViewModel,
        mediaSource: MediaSource = .photoLibrary,
        isExportDisabled: Bool = false,
        onDateAdjusted: ((String, Date, TimeZone, Bool) -> Void)? = nil,
        onMetadataRefreshed: ((String, PhotoExifMetadata) -> Void)? = nil,
        onFilenameChanged: ((String, String) -> Void)? = nil,
        onFolderItemUpdated: ((String, PhotoItem) -> Void)? = nil,
        onDeleted: ((String) -> Void)? = nil
    ) {
        let allItems = items.isEmpty ? [item] : items
        let initialIndex = allItems.firstIndex(where: { $0.id == item.id }) ?? 0
        let currentItem = allItems[initialIndex]
        let vm = PhotoDetailViewModel(item: currentItem, mediaSource: mediaSource)
        vm.onDateAdjusted = onDateAdjusted
        vm.onMetadataRefreshed = onMetadataRefreshed
        vm.onFilenameChanged = onFilenameChanged
        vm.onFolderItemUpdated = onFolderItemUpdated
        vm.onDeleted = onDeleted
        _viewModel = StateObject(wrappedValue: vm)
        self.listViewModel = listViewModel
        self.mediaSource = mediaSource
        self.isExportDisabled = isExportDisabled
        self.onDateAdjusted = onDateAdjusted
        self.onMetadataRefreshed = onMetadataRefreshed
        self.onFilenameChanged = onFilenameChanged
        self.onFolderItemUpdated = onFolderItemUpdated
        self.onDeleted = onDeleted
        _items = State(initialValue: allItems)
        _currentIndex = State(initialValue: initialIndex)
    }

    private func goToNext(width: CGFloat) {
        performSlideTransition(step: 1, width: width)
    }

    private func goToPrevious(width: CGFloat) {
        performSlideTransition(step: -1, width: width)
    }

    private func performSlideTransition(step: Int, width: CGFloat) {
        guard !isTransitioning, !isMediaZoomed else { return }
        let nextIndex = currentIndex + step
        guard nextIndex >= 0 && nextIndex < items.count else {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
            return
        }

        let oldItem = items[currentIndex]
        if let currentImg = viewModel.highResImage {
            viewModel.saveImageToCache(currentImg, for: oldItem.id)
        }

        let targetItem = items[nextIndex]
        if !targetItem.isVideo {
            viewModel.stopVideoAndRelinquishAudio()
        } else {
            viewModel.pauseVideo()
        }

        isTransitioning = true
        let targetOffset: CGFloat = step > 0 ? -width : width
        withAnimation(.easeInOut(duration: 0.22)) {
            slideOffset = targetOffset
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            var noAnimation = Transaction()
            noAnimation.disablesAnimations = true
            withTransaction(noAnimation) {
                currentIndex = nextIndex
                slideOffset = 0
                isTransitioning = false
            }
            let newActiveItem = items[currentIndex]
            viewModel.setItem(newActiveItem)
            viewModel.preloadAdjacentItems(currentIndex: currentIndex, items: items)
        }
    }

    private var visibleSlides: [(index: Int, item: PhotoItem)] {
        guard !items.isEmpty else { return [] }
        let lower = max(0, currentIndex - 1)
        let upper = min(items.count - 1, currentIndex + 1)
        return (lower...upper).map { ($0, items[$0]) }
    }

    private var isCurrentMediaLandscape: Bool {
        if !viewModel.isVideo,
           let img = viewModel.highResImage
            ?? viewModel.imageCache[viewModel.item.id]
            ?? FolderMediaService.shared.cachedThumbnail(for: viewModel.item, in: viewModel.mediaSource) {
            return img.size.width > img.size.height
        }
        if viewModel.metadata.pixelWidth > 0 && viewModel.metadata.pixelHeight > 0 {
            return viewModel.metadata.pixelWidth > viewModel.metadata.pixelHeight
        }
        if viewModel.item.pixelWidth > 0 && viewModel.item.pixelHeight > 0 {
            return viewModel.item.pixelWidth > viewModel.item.pixelHeight
        }
        if let img = viewModel.highResImage
            ?? viewModel.imageCache[viewModel.item.id]
            ?? FolderMediaService.shared.cachedThumbnail(for: viewModel.item, in: viewModel.mediaSource) {
            return img.size.width > img.size.height
        }
        return false
    }

    private var shouldShowFullScreenButton: Bool {
        !isTransitioning && !viewModel.isVideo && isFullScreenButtonVisible
    }

    private func hideFullScreenButton() {
        fullScreenButtonHideTask?.cancel()
        fullScreenButtonHideTask = nil
        isFullScreenButtonVisible = false
    }

    private func revealFullScreenButton() {
        fullScreenButtonHideTask?.cancel()
        guard !viewModel.isVideo else {
            isFullScreenButtonVisible = false
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            isFullScreenButtonVisible = true
        }
        fullScreenButtonHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isFullScreenButtonVisible = false
            }
        }
    }

    private var isCurrentInterfaceLandscape: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.effectiveGeometry.interfaceOrientation.isLandscape }
            .first ?? false
    }

    private var currentWindowSafeAreaInsets: UIEdgeInsets {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyWindow = windowScene.windows.first(where: \.isKeyWindow) {
                return keyWindow.safeAreaInsets
            }
            if let firstWindow = windowScene.windows.first {
                return firstWindow.safeAreaInsets
            }
        }
        return .zero
    }

    private func syncOrientationForFullScreen() {
        if isFullScreen {
            // Keep the UIWindow locked to the current interface orientation instead of triggering
            // UIWindowScene geometry rotation, which causes SwiftUI's root hosting view to jump up/right.
            // Landscape media entered from portrait is rotated directly inside fullScreenOverlayView.
            let mask: UIInterfaceOrientationMask = isCurrentInterfaceLandscape ? .landscape : .portrait
            guard AppDelegate.orientationLock != mask else { return }
            AppDelegate.setOrientationLock(mask)
        } else {
            guard AppDelegate.orientationLock != .allButUpsideDown else { return }
            AppDelegate.setOrientationLock(.allButUpsideDown)
        }
    }

    private func exitFullScreen() {
        guard isFullScreen else { return }
        toggleFullScreen()
    }

    private func toggleFullScreen() {
        let shouldResumePlayback = (viewModel.avPlayer?.timeControlStatus == .playing || (viewModel.avPlayer?.rate ?? 0) > 0)
        isMediaZoomed = false
        hideFullScreenButton()
        fullScreenTransitionGeneration += 1
        let generation = fullScreenTransitionGeneration

        if !isFullScreen {
            isFullScreenTransitionActive = true
            isFullScreenOverlayMounted = true
            AppDelegate.setOrientationLock(isCurrentInterfaceLandscape ? .landscape : .portrait)
            DispatchQueue.main.async {
                guard self.fullScreenTransitionGeneration == generation else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    self.isFullScreen = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                guard self.fullScreenTransitionGeneration == generation, self.isFullScreen else { return }
                self.isFullScreenTransitionActive = false
                self.syncOrientationForFullScreen()
            }
        } else {
            isFullScreenTransitionActive = true
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                isFullScreen = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                guard self.fullScreenTransitionGeneration == generation, !self.isFullScreen else { return }
                self.isFullScreenOverlayMounted = false
                self.isFullScreenTransitionActive = false
                self.syncOrientationForFullScreen()
            }
        }

        if shouldResumePlayback {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if (viewModel.avPlayer?.rate ?? 0) == 0 {
                    viewModel.avPlayer?.play()
                }
            }
        }
    }

    @ViewBuilder
    private func mediaDeck(containerWidth: CGFloat, containerHeight: CGFloat, isFullScreenDeck: Bool) -> some View {
        let isPlayerHost = isFullScreenDeck ? isFullScreenOverlayMounted : !isFullScreenOverlayMounted

        // Keep previous, current, and next slides continuously mounted so both outgoing and
        // incoming media slide side-by-side even when previews finish loading mid-swipe.
        ForEach(visibleSlides, id: \.item.id) { slide in
            let relativeSlot = CGFloat(slide.index - currentIndex)
            let isCurrent = slide.index == currentIndex
            if !isFullScreenDeck || !isFullScreenTransitionActive || isCurrent || slideOffset != 0 {
                DetailMediaSlideView(
                    item: slide.item,
                    isCurrentItem: isCurrent && !isTransitioning,
                    isPlayerHost: isPlayerHost,
                    isFullScreen: isFullScreenDeck,
                    containerHeight: containerHeight,
                    viewModel: viewModel,
                    playerHostingBox: playerHostingBox,
                    isMediaZoomed: isCurrent ? $isMediaZoomed : .constant(false),
                    onSwipeLeft: { goToNext(width: containerWidth) },
                    onSwipeRight: { goToPrevious(width: containerWidth) },
                    onToggleFullScreen: isCurrent && isPlayerHost ? { toggleFullScreen() } : nil,
                    onPinchToExitFullScreen: isFullScreenDeck ? { exitFullScreen() } : nil
                )
                .frame(width: containerWidth, height: containerHeight)
                .clipped()
                .compositingGroup()
                .offset(x: relativeSlot * containerWidth + slideOffset)
            }
        }
    }

    private func fullScreenToggleButton(isExpanded: Bool) -> some View {
        Button {
            toggleFullScreen()
        } label: {
            Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial)
                .background(Color.black.opacity(0.4))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
        .accessibilityLabel(isExpanded ? "Exit Full Screen" : "Enter Full Screen")
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 20) {
                // Media Viewer Container (Photo Zoom or Playable Video)
                GeometryReader { geo in
                    let containerWidth = geo.size.width
                    let containerHeight = geo.size.height

                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.9)

                        mediaDeck(
                            containerWidth: containerWidth,
                            containerHeight: containerHeight,
                            isFullScreenDeck: false
                        )

                        if viewModel.isEditedMedia && !isTransitioning {
                            versionPicker
                                .padding(.bottom, 12)
                                .transition(.opacity)
                        }
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            if !viewModel.isVideo {
                                revealFullScreenButton()
                            }
                        }
                    )
                    .overlay(alignment: .topTrailing) {
                        if !isTransitioning && !viewModel.isVideo {
                            fullScreenToggleButton(isExpanded: false)
                                .padding(.top, 8)
                                .padding(.trailing, 16)
                                .opacity(shouldShowFullScreenButton ? 1 : 0)
                                .allowsHitTesting(shouldShowFullScreenButton)
                                .animation(.easeInOut(duration: 0.15), value: shouldShowFullScreenButton)
                        }
                    }
                    .frame(width: containerWidth, height: containerHeight)
                    .clipped()
                    .background(
                        Color.clear.preference(
                            key: DetailInlineMediaFramePreferenceKey.self,
                            value: geo.frame(in: .global)
                        )
                    )
                }
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(isFullScreenOverlayMounted ? 0 : 1)
                .allowsHitTesting(!isFullScreenOverlayMounted)
                .padding(.horizontal, 12)
                .padding(.top, 8)

                VStack(spacing: 16) {
                    // 1. Date, Time & Timezone Card with Adjust Button
                    DateTimeCardView(metadata: viewModel.metadata) {
                        viewModel.isShowingAdjustDateSheet = true
                    }
                    .padding(.horizontal, 16)

                    // 2. GPS Location Map (placed immediately after Date, Time & Timezone)
                    if let location = viewModel.metadata.location {
                        PhotoLocationMapView(
                            location: location,
                            address: viewModel.geocodedAddress,
                            isGPSAdjusted: viewModel.metadata.isGPSAdjusted,
                            onOpenInMaps: {
                                viewModel.openInAppleMaps()
                            }
                        )
                    }

                    // 3. Camera & Lens Card
                    if viewModel.metadata.hasCameraOrLensData {
                        CameraLensCardView(metadata: viewModel.metadata)
                            .padding(.horizontal, 16)
                    }

                    // 4. File Specifications Card
                    FileInfoCardView(metadata: viewModel.metadata)
                        .padding(.horizontal, 16)

                    // 5. EXIF Date & GPS Card
                    if !viewModel.metadata.rawDateAndGPSFields.isEmpty {
                        ExifDateGPSCardView(metadata: viewModel.metadata)
                            .padding(.horizontal, 16)
                    }
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            .padding(.bottom, 80)
        }
        .scrollDisabled(isFullScreenOverlayMounted)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Spacer()

                    // Floating Delete Button
                    Button(role: .destructive) {
                        if mediaSource.isFolder {
                            viewModel.isShowingDeleteConfirmation = true
                        } else {
                            Task {
                                let deletedID = viewModel.item.id
                                let success = await viewModel.deletePhoto()
                                if success {
                                    onDeleted?(deletedID)
                                    dismiss()
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Delete")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial)
                        .background(Color.red.opacity(0.14))
                        .foregroundColor(.red)
                        .clipShape(Capsule())
                        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
                    }

                    // Floating Export / Apply Button
                    let showsApply = viewModel.showsApplyAction
                    let cannotExport = isExportDisabled || listViewModel.isExportDisabled || !viewModel.item.isAnalyzed
                    Button {
                        if showsApply {
                            listViewModel.onBeforeFinalSwapInPlace = { [weak viewModel] appliedItem in
                                await viewModel?.releaseMediaHandleIfNeededForSwap(itemID: appliedItem.id)
                            }
                            listViewModel.onFolderItemAppliedInPlace = { [weak viewModel, weak listViewModel] oldID, cleared in
                                viewModel?.handleAppliedInPlaceResult(
                                    oldID: oldID,
                                    cleared: cleared,
                                    isProgressSheetShowing: { listViewModel?.isShowingExportProgress ?? false }
                                )
                            }
                            listViewModel.initiateExport(items: [viewModel.item])
                        } else {
                            listViewModel.initiateExport(items: [viewModel.currentItemForExport])
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showsApply ? "wand.and.stars" : "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                            Text(showsApply ? "Apply" : "Export")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(cannotExport ? Color.gray.opacity(0.3) : Color.blue.opacity(0.85))
                        .foregroundColor(cannotExport ? Color.white.opacity(0.6) : .white)
                        .clipShape(Capsule())
                        .shadow(color: cannotExport ? .clear : Color.blue.opacity(0.35), radius: 6, x: 0, y: 3)
                    }
                    .disabled(cannotExport)
                }
                .opacity(0.8)
                .padding(.trailing, 16)

                FloatingBannerBottomSpacer(coordinator: listViewModel.progressCoordinator)
            }
            .padding(.bottom, 0)
            .opacity(isFullScreen ? 0 : 1)
            .allowsHitTesting(!isFullScreen)
        }

        if isFullScreenOverlayMounted {
            fullScreenOverlayView
                .zIndex(50)
        }
        }
        .onPreferenceChange(DetailInlineMediaFramePreferenceKey.self) { frame in
            if !isFullScreen && frame.width > 1 && frame.height > 1 {
                inlineMediaGlobalFrame = frame
            }
        }
        .navigationTitle(viewModel.item.filename)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isFullScreen)
        .toolbar(isFullScreen ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(isFullScreen)
        .onAppear {
            listViewModel.onBeforeFinalSwapInPlace = { [weak viewModel] appliedItem in
                await viewModel?.releaseMediaHandleIfNeededForSwap(itemID: appliedItem.id)
            }
            listViewModel.onFolderItemAppliedInPlace = { [weak viewModel, weak listViewModel] oldID, cleared in
                viewModel?.handleAppliedInPlaceResult(
                    oldID: oldID,
                    cleared: cleared,
                    isProgressSheetShowing: { listViewModel?.isShowingExportProgress ?? false }
                )
            }
        }
        .onChange(of: listViewModel.isShowingExportProgress) { _, isShowing in
            if !isShowing {
                Task {
                    await viewModel.performPendingVideoReloadIfNeeded()
                }
            }
        }
        .sheet(isPresented: $viewModel.isShowingAdjustDateSheet) {
            AdjustDateTimeSheet(
                initialDate: viewModel.metadata.creationDate,
                originalEmbeddedDate: viewModel.metadata.embeddedDate,
                initialTimeZone: viewModel.metadata.timeZone,
                isPreviouslyAdjusted: viewModel.metadata.isDateAdjusted,
                onSave: { newDate, newTimeZone in
                    Task {
                        await viewModel.adjustDateTime(newDate: newDate, newTimeZone: newTimeZone)
                        if currentIndex >= 0 && currentIndex < items.count {
                            items[currentIndex] = viewModel.item
                        }
                    }
                },
                onRevert: {
                    Task {
                        await viewModel.revertDateTime()
                        if currentIndex >= 0 && currentIndex < items.count {
                            items[currentIndex] = viewModel.item
                        }
                    }
                }
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        editedFilename = viewModel.item.filename
                        isShowingRenameAlert = true
                    } label: {
                        Image(systemName: "pencil")
                    }

                    Button {
                        viewModel.rotateClockwise90()
                        if currentIndex >= 0 && currentIndex < items.count {
                            items[currentIndex] = viewModel.item
                        }
                    } label: {
                        Image(systemName: "rotate.right")
                    }
                    .disabled(viewModel.isLoadingMedia)
                    .accessibilityLabel("Rotate 90° Clockwise")
                }
            }
        }
        .alert(mediaSource.isFolder ? "Rename File" : "Edit Exported File Name", isPresented: $isShowingRenameAlert) {
            TextField(mediaSource.isFolder ? "File Name" : "Exported File Name", text: $editedFilename)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                viewModel.updateFilename(editedFilename)
                if !mediaSource.isFolder, currentIndex >= 0 && currentIndex < items.count {
                    items[currentIndex] = viewModel.item
                }
            }
        } message: {
            Text(mediaSource.isFolder ? "Enter a new file name for this file on disk." : "Enter a new exported file name for this file.")
        }
        .alert("Delete File?", isPresented: $viewModel.isShowingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    let deletedID = viewModel.item.id
                    let success = await viewModel.deletePhoto()
                    if success {
                        onDeleted?(deletedID)
                        dismiss()
                    }
                }
            }
        } message: {
            Text("This will permanently delete \"\(viewModel.item.filename)\" from \(mediaSource.navigationTitle).")
        }
        .alert("Rename Failed", isPresented: Binding(
            get: { viewModel.renameError != nil },
            set: { if !$0 { viewModel.renameError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.renameError = nil }
        } message: {
            Text(viewModel.renameError ?? "")
        }
        .onChange(of: viewModel.shouldDismiss) { shouldDismiss in
            if shouldDismiss {
                dismiss()
            }
        }
        .onChange(of: viewModel.item) { updatedItem in
            if currentIndex >= 0 && currentIndex < items.count && items[currentIndex].id == updatedItem.id {
                items[currentIndex] = updatedItem
            }
        }
        .onAppear {
            viewModel.onDateAdjusted = onDateAdjusted
            viewModel.onMetadataRefreshed = onMetadataRefreshed
            viewModel.onFilenameChanged = onFilenameChanged
            viewModel.onFolderItemUpdated = { oldID, updated in
                if let idx = items.firstIndex(where: { $0.id == oldID }) {
                    items[idx] = updated
                }
                onFolderItemUpdated?(oldID, updated)
            }
            viewModel.onDeleted = onDeleted
            guard !hasAppeared else { return }
            hasAppeared = true
            hideFullScreenButton()
            viewModel.loadData()
            viewModel.preloadAdjacentItems(currentIndex: currentIndex, items: items)
            if viewModel.shouldDismiss {
                dismiss()
                return
            }
            if viewModel.requiresOnDemandStream {
                viewModel.startStreamingRemoteVideo()
            } else {
                viewModel.playVideo()
            }
        }
        .onDisappear {
            viewModel.flushPendingPhotoKitRotation()
            fullScreenButtonHideTask?.cancel()
            viewModel.stopVideoAndRelinquishAudio()
            if AppDelegate.orientationLock != .allButUpsideDown {
                AppDelegate.setOrientationLock(.allButUpsideDown)
            }
        }
        .onChange(of: isFullScreen) { _ in
            if !isFullScreenTransitionActive {
                syncOrientationForFullScreen()
            }
        }
        .onChange(of: currentIndex) { _ in
            hideFullScreenButton()
            if isFullScreen {
                syncOrientationForFullScreen()
            }
        }
        .onChange(of: viewModel.isVideo) { _ in
            hideFullScreenButton()
        }
        .onChange(of: viewModel.metadata.pixelWidth) { _ in
            if isFullScreen {
                syncOrientationForFullScreen()
            }
        }
        .onChange(of: viewModel.highResImage) { _ in
            if isFullScreen {
                syncOrientationForFullScreen()
            }
        }
    }

    @ViewBuilder
    private var fullScreenOverlayView: some View {
        let windowSafeInsets = currentWindowSafeAreaInsets

        GeometryReader { geo in
            let overlayOrigin = geo.frame(in: .global).origin
            let relativeInline: CGRect = {
                if inlineMediaGlobalFrame.width > 1 && inlineMediaGlobalFrame.height > 1 {
                    return CGRect(
                        x: inlineMediaGlobalFrame.minX - overlayOrigin.x,
                        y: inlineMediaGlobalFrame.minY - overlayOrigin.y,
                        width: inlineMediaGlobalFrame.width,
                        height: inlineMediaGlobalFrame.height
                    )
                }
                return CGRect(x: 12, y: max(12, windowSafeInsets.top + 8), width: max(1, geo.size.width - 24), height: 380)
            }()

            let isPortraitScreen = geo.size.height > geo.size.width
            let useRotatedLandscape = isFullScreen && isCurrentMediaLandscape && isPortraitScreen
            let currentWidth: CGFloat = {
                if !isFullScreen { return relativeInline.width }
                return useRotatedLandscape ? geo.size.height : geo.size.width
            }()
            let currentHeight: CGFloat = {
                if !isFullScreen { return relativeInline.height }
                return useRotatedLandscape ? geo.size.width : geo.size.height
            }()
            let currentCenter = isFullScreen
                ? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                : CGPoint(x: relativeInline.midX, y: relativeInline.midY)
            let currentRotationDegrees: Double = useRotatedLandscape ? 90 : 0
            let currentCornerRadius: CGFloat = isFullScreen ? 0 : 16

            ZStack {
                Color.black
                    .opacity(isFullScreen ? 1 : 0)

                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.9)

                    mediaDeck(
                        containerWidth: currentWidth,
                        containerHeight: currentHeight,
                        isFullScreenDeck: true
                    )

                    if viewModel.isEditedMedia && !viewModel.isVideo && !isTransitioning && isFullScreen {
                        versionPicker
                            .padding(.bottom, useRotatedLandscape ? 20 : max(20, windowSafeInsets.bottom + 8))
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isFullScreen && !isTransitioning && !viewModel.isVideo {
                        fullScreenToggleButton(isExpanded: true)
                            .padding(.top, useRotatedLandscape ? 16 : max(16, windowSafeInsets.top + 8))
                            .padding(.trailing, useRotatedLandscape ? max(20, windowSafeInsets.bottom + 4) : 16)
                            .opacity(shouldShowFullScreenButton ? 1 : 0)
                            .allowsHitTesting(shouldShowFullScreenButton)
                            .animation(.easeInOut(duration: 0.15), value: shouldShowFullScreenButton)
                    }
                }
                .frame(width: currentWidth, height: currentHeight)
                .clipShape(RoundedRectangle(cornerRadius: currentCornerRadius, style: .continuous))
                .rotationEffect(.degrees(currentRotationDegrees), anchor: .center)
                .position(x: currentCenter.x, y: currentCenter.y)
                .animation(.spring(response: 0.34, dampingFraction: 0.88), value: useRotatedLandscape)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if isFullScreen && !viewModel.isVideo {
                            revealFullScreenButton()
                        }
                    }
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

// MARK: - Slide Media Item View (Self-contained display to prevent any black flash during transition)

struct DetailMediaSlideView: View {
    let item: PhotoItem
    let isCurrentItem: Bool
    let isPlayerHost: Bool
    let isFullScreen: Bool
    let containerHeight: CGFloat
    @ObservedObject var viewModel: PhotoDetailViewModel
    var playerHostingBox: DetailPlayerHostingBox? = nil
    @Binding var isMediaZoomed: Bool
    var onSwipeLeft: () -> Void
    var onSwipeRight: () -> Void
    var onToggleFullScreen: (() -> Void)? = nil
    var onPinchToExitFullScreen: (() -> Void)? = nil

    @State private var staticImage: UIImage?
    @State private var videoPoster: UIImage?

    private static func rotatedFolderImageIfNeeded(_ image: UIImage?, item: PhotoItem, mediaSource: MediaSource) -> UIImage? {
        guard let image, mediaSource.isFolder else { return image }
        let steps = ExifMetadataService.clockwiseSteps(forDegrees: item.pendingRotationDegrees)
        guard steps != 0 else { return image }
        return ExifMetadataService.rotateUIImage(image, clockwiseSteps: steps)
    }

    init(
        item: PhotoItem,
        isCurrentItem: Bool,
        isPlayerHost: Bool = true,
        isFullScreen: Bool = false,
        containerHeight: CGFloat = 380,
        viewModel: PhotoDetailViewModel,
        playerHostingBox: DetailPlayerHostingBox? = nil,
        isMediaZoomed: Binding<Bool>,
        onSwipeLeft: @escaping () -> Void,
        onSwipeRight: @escaping () -> Void,
        onToggleFullScreen: (() -> Void)? = nil,
        onPinchToExitFullScreen: (() -> Void)? = nil
    ) {
        self.item = item
        self.isCurrentItem = isCurrentItem
        self.isPlayerHost = isPlayerHost
        self.isFullScreen = isFullScreen
        self.containerHeight = containerHeight
        self.viewModel = viewModel
        self.playerHostingBox = playerHostingBox
        self._isMediaZoomed = isMediaZoomed
        self.onSwipeLeft = onSwipeLeft
        self.onSwipeRight = onSwipeRight
        self.onToggleFullScreen = onToggleFullScreen
        self.onPinchToExitFullScreen = onPinchToExitFullScreen

        let initialImg: UIImage? = {
            if let cached = viewModel.imageCache[item.id] {
                return cached
            }
            if item.id == viewModel.item.id, let highRes = viewModel.highResImage {
                return highRes
            }
            if let folderThumb = FolderMediaService.shared.cachedThumbnail(for: item, in: viewModel.mediaSource) {
                return Self.rotatedFolderImageIfNeeded(folderThumb, item: item, mediaSource: viewModel.mediaSource)
            }
            guard let asset = item.asset else { return nil }
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.version = .current
            options.isNetworkAccessAllowed = false
            var syncImg: UIImage? = nil
            PhotoLibraryService.shared.imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 800, height: 800),
                contentMode: .aspectFit,
                options: options
            ) { img, _ in
                syncImg = img
            }
            return syncImg
        }()
        self._staticImage = State(initialValue: initialImg)
        self._videoPoster = State(initialValue: item.isVideo ? initialImg : nil)
    }

    var body: some View {
        ZStack {
            if item.isVideo {
                ZStack {
                    let currentPoster = (item.id == viewModel.item.id) ? viewModel.highResImage : nil
                    let poster = currentPoster ?? videoPoster ?? staticImage ?? viewModel.imageCache[item.id]
                    let isStartingRemote = viewModel.mediaSource.isRemote && (item.id == viewModel.item.id) && viewModel.isPreparingVideoStream
                    let showRemotePlayOverlay = viewModel.mediaSource.isRemote && (item.id != viewModel.item.id || viewModel.avPlayer == nil || isStartingRemote)

                    // Always show the video poster frame behind the player to prevent any black blackout during transitions
                    if let poster {
                        Image(uiImage: poster)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: containerHeight)
                            .mediaSwipeGesture(
                                isBottomScrubExcluded: true,
                                containerHeight: containerHeight,
                                onSwipeLeft: onSwipeLeft,
                                onSwipeRight: onSwipeRight
                            )
                            .fullScreenPinchToExitGesture(
                                isEnabled: isFullScreen,
                                onPinchExit: { onPinchToExitFullScreen?() }
                            )
                    }

                    if isPlayerHost, item.id == viewModel.item.id, let player = viewModel.avPlayer {
                        DetailVideoPlayer(
                            player: player,
                            isFullScreen: isFullScreen,
                            hostingBox: playerHostingBox,
                            onToggleFullScreen: onToggleFullScreen,
                            onPinchToExitFullScreen: isFullScreen ? onPinchToExitFullScreen : nil
                        )
                            .frame(maxWidth: .infinity)
                            .frame(height: containerHeight)
                            .mediaSwipeGesture(
                                isBottomScrubExcluded: true,
                                containerHeight: containerHeight,
                                onSwipeLeft: onSwipeLeft,
                                onSwipeRight: onSwipeRight
                            )
                    }

                    if showRemotePlayOverlay {
                        ZStack {
                            // Keep poster visible over VideoPlayer's opaque black view until playback renders a frame
                            if isStartingRemote, let poster {
                                Image(uiImage: poster)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: containerHeight)
                            }

                            if item.id == viewModel.item.id {
                                if let streamErr = viewModel.videoStreamError {
                                    VStack(spacing: 12) {
                                        Text(streamErr)
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color.red.opacity(0.75))
                                            .clipShape(Capsule())
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 20)

                                        Button {
                                            viewModel.startStreamingRemoteVideo()
                                        } label: {
                                            Label("Retry", systemImage: "arrow.clockwise")
                                                .font(.caption.weight(.semibold))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 8)
                                                .background(.ultraThinMaterial)
                                                .background(Color.black.opacity(0.4))
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                } else {
                                    ProgressView()
                                        .tint(.white)
                                        .scaleEffect(1.25)
                                        .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 2)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: containerHeight)
                        .contentShape(Rectangle())
                        .mediaSwipeGesture(
                            isBottomScrubExcluded: true,
                            containerHeight: containerHeight,
                            onSwipeLeft: onSwipeLeft,
                            onSwipeRight: onSwipeRight
                        )
                        .fullScreenPinchToExitGesture(
                            isEnabled: isFullScreen,
                            onPinchExit: { onPinchToExitFullScreen?() }
                        )
                    } else if item.id == viewModel.item.id && viewModel.avPlayer == nil {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.25)
                            .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 2)
                            .frame(maxWidth: .infinity)
                            .frame(height: containerHeight)
                            .contentShape(Rectangle())
                            .fullScreenPinchToExitGesture(
                                isEnabled: isFullScreen,
                                onPinchExit: { onPinchToExitFullScreen?() }
                            )
                    }
                }
            } else {
                let currentImg = (item.id == viewModel.item.id) ? viewModel.highResImage : nil
                let imageToUse = currentImg ?? staticImage ?? viewModel.imageCache[item.id]
                if let image = imageToUse {
                    ZoomableImageView(
                        image: image,
                        isZoomed: $isMediaZoomed,
                        onSwipeLeft: onSwipeLeft,
                        onSwipeRight: onSwipeRight,
                        onPinchToExitFullScreen: isFullScreen ? onPinchToExitFullScreen : nil
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: containerHeight)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("Loading high resolution photo...")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: containerHeight)
                    .contentShape(Rectangle())
                    .fullScreenPinchToExitGesture(
                        isEnabled: isFullScreen,
                        onPinchExit: { onPinchToExitFullScreen?() }
                    )
                }
            }
        }
        .onAppear {
            if staticImage == nil {
                loadImmediateImage()
            }
            if item.isVideo && videoPoster == nil {
                loadImmediateVideoPoster()
            }
        }
        .onChange(of: viewModel.highResImage) { newImg in
            // Only update staticImage if this slide is for the currently active item and newImg is non-nil
            // Never clear staticImage to nil so the slide never blacks out when swiping away
            if item.id == viewModel.item.id, let img = newImg {
                staticImage = img
                if item.isVideo {
                    videoPoster = img
                }
                viewModel.saveImageToCache(img, for: item.id)
            }
        }
    }

    private func loadImmediateImage() {
        if let cached = viewModel.imageCache[item.id] {
            staticImage = cached
            return
        }
        if item.id == viewModel.item.id, let highRes = viewModel.highResImage {
            staticImage = highRes
            return
        }
        guard let asset = item.asset else {
            let targetItem = item
            let source = viewModel.mediaSource
            Task {
                if let thumb = await FolderMediaService.shared.loadThumbnail(for: targetItem, in: source, maxPixelSize: 800) {
                    let rotatedThumb = Self.rotatedFolderImageIfNeeded(thumb, item: targetItem, mediaSource: source) ?? thumb
                    await MainActor.run {
                        if self.staticImage == nil {
                            self.staticImage = rotatedThumb
                        }
                        if self.viewModel.imageCache[targetItem.id] == nil {
                            self.viewModel.saveImageToCache(rotatedThumb, for: targetItem.id)
                        }
                    }
                }
            }
            return
        }
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.version = .current
        options.isNetworkAccessAllowed = true
        PhotoLibraryService.shared.imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: 800, height: 800),
            contentMode: .aspectFit,
            options: options
        ) { img, _ in
            if let img = img {
                Task { @MainActor in
                    if self.staticImage == nil {
                        self.staticImage = img
                    }
                    self.viewModel.saveImageToCache(img, for: self.item.id)
                }
            }
        }
    }

    private func loadImmediateVideoPoster() {
        if item.asset != nil, let cached = viewModel.imageCache[item.id] {
            videoPoster = cached
            return
        }
        guard let asset = item.asset else {
            let targetItem = item
            let source = viewModel.mediaSource
            Task {
                if let cached = self.viewModel.imageCache[targetItem.id] {
                    await MainActor.run {
                        self.videoPoster = cached
                    }
                    return
                }
                if let thumb = await FolderMediaService.shared.loadThumbnail(for: targetItem, in: source, maxPixelSize: 800) {
                    let rotatedThumb = Self.rotatedFolderImageIfNeeded(thumb, item: targetItem, mediaSource: source) ?? thumb
                    await MainActor.run {
                        if self.videoPoster == nil {
                            self.videoPoster = rotatedThumb
                        }
                        if self.viewModel.imageCache[targetItem.id] == nil {
                            self.viewModel.saveImageToCache(rotatedThumb, for: targetItem.id)
                        }
                    }
                }
            }
            return
        }
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = (asset.hasAdjustments || item.isEdited) ? .opportunistic : .fastFormat
        options.resizeMode = .fast
        options.version = .current
        options.isNetworkAccessAllowed = true
        PhotoLibraryService.shared.imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: 800, height: 800),
            contentMode: .aspectFit,
            options: options
        ) { img, _ in
            if let img = img {
                Task { @MainActor in
                    self.videoPoster = img
                    if self.item.id == self.viewModel.item.id && self.viewModel.highResImage == nil {
                        self.viewModel.saveImageToCache(img, for: self.item.id)
                    }
                }
            }
        }
    }
}

    // MARK: - Version Switcher (Edited vs Original)

    private var versionPicker: some View {
        HStack(spacing: 0) {
            ForEach(PhotoDetailViewModel.MediaVersion.allCases) { version in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        viewModel.switchVersion(version)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: version == .edited ? "wand.and.stars" : "photo")
                            .font(.system(size: 11, weight: .bold))
                        Text(version.rawValue)
                            .font(.system(size: 12, weight: viewModel.selectedVersion == version ? .bold : .medium))
                    }
                    .foregroundColor(viewModel.selectedVersion == version ? .white : .white.opacity(0.8))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        Group {
                            if viewModel.selectedVersion == version {
                                Color.blue.opacity(0.85)
                                    .clipShape(Capsule())
                            } else {
                                Color.clear
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.25))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
        .opacity(0.8)
    }
}

fileprivate extension View {
    func mediaSwipeGesture(
        isBottomScrubExcluded: Bool = false,
        containerHeight: CGFloat = 380,
        onSwipeLeft: @escaping () -> Void,
        onSwipeRight: @escaping () -> Void
    ) -> some View {
        self.highPriorityGesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    if isBottomScrubExcluded && value.startLocation.y > max(0, containerHeight - 60) {
                        return
                    }
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    let predicted = value.predictedEndTranslation.width
                    if abs(horizontal) > abs(vertical) {
                        if horizontal < -25 || predicted < -70 {
                            onSwipeLeft()
                        } else if horizontal > 25 || predicted > 70 {
                            onSwipeRight()
                        }
                    }
                }
        )
    }

    @ViewBuilder
    func fullScreenPinchToExitGesture(
        isEnabled: Bool,
        onPinchExit: @escaping () -> Void
    ) -> some View {
        if isEnabled {
            self.simultaneousGesture(
                MagnificationGesture()
                    .onEnded { value in
                        if value <= 0.88 {
                            onPinchExit()
                        }
                    }
            )
        } else {
            self
        }
    }
}

// MARK: - Detail Video Player (Hosts AVPlayerViewController directly and wires its native full-screen button)
// Hosting AVPlayerViewController directly avoids a SwiftUI VideoPlayer preference bug where NavigationStack hides its navigation bar when playback fails and the player is torn down.

private struct DetailVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let isFullScreen: Bool
    var hostingBox: DetailPlayerHostingBox? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var onPinchToExitFullScreen: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            hostingBox: hostingBox,
            onToggleFullScreen: onToggleFullScreen,
            onPinchToExitFullScreen: onPinchToExitFullScreen
        )
    }

    func makeUIViewController(context: Context) -> VideoPlayerContainerViewController {
        let containerVC = VideoPlayerContainerViewController()
        containerVC.view.backgroundColor = .clear
        context.coordinator.attach(
            to: containerVC,
            player: player,
            isFullScreen: isFullScreen,
            onToggleFullScreen: onToggleFullScreen,
            onPinchToExitFullScreen: onPinchToExitFullScreen
        )
        return containerVC
    }

    func updateUIViewController(_ uiViewController: VideoPlayerContainerViewController, context: Context) {
        context.coordinator.update(
            player: player,
            isFullScreen: isFullScreen,
            onToggleFullScreen: onToggleFullScreen,
            onPinchToExitFullScreen: onPinchToExitFullScreen
        )
    }

    static func dismantleUIViewController(_ uiViewController: VideoPlayerContainerViewController, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    final class VideoPlayerContainerViewController: UIViewController {
        var onHierarchyChanged: (() -> Void)?

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            onHierarchyChanged?()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onHierarchyChanged?()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var hostingBox: DetailPlayerHostingBox?
        private var onToggleFullScreen: (() -> Void)?
        private var onPinchToExitFullScreen: (() -> Void)?
        private var currentPlayer: AVPlayer?
        private var currentIsFullScreen: Bool?
        private weak var containerVC: VideoPlayerContainerViewController?
        private var playerViewController: AVPlayerViewController?
        private var pinchRecognizer: UIPinchGestureRecognizer?
        private var didTriggerPinchExit: Bool = false
        private weak var observedFullScreenButton: UIControl?
        private var buttonObservations: [NSKeyValueObservation] = []
        private var playerObservations: [NSKeyValueObservation] = []
        private var discoveryTask: Task<Void, Never>?
        private var discoveryRetryCount: Int = 0
        private var isConfiguringButton: Bool = false
        private var isDismantled: Bool = false

        init(
            hostingBox: DetailPlayerHostingBox?,
            onToggleFullScreen: (() -> Void)?,
            onPinchToExitFullScreen: (() -> Void)?
        ) {
            self.hostingBox = hostingBox
            self.onToggleFullScreen = onToggleFullScreen
            self.onPinchToExitFullScreen = onPinchToExitFullScreen
        }

        func attach(
            to containerVC: VideoPlayerContainerViewController,
            player: AVPlayer,
            isFullScreen: Bool,
            onToggleFullScreen: (() -> Void)?,
            onPinchToExitFullScreen: (() -> Void)?
        ) {
            self.containerVC = containerVC
            self.currentPlayer = player
            self.currentIsFullScreen = isFullScreen
            self.onToggleFullScreen = onToggleFullScreen
            self.onPinchToExitFullScreen = onPinchToExitFullScreen

            let playerVC: AVPlayerViewController
            if let existing = hostingBox?.playerViewController {
                playerVC = existing
                if existing.player !== player {
                    existing.player = player
                }
                hostingBox?.currentPlayer = player
                if playerVC.parent !== containerVC {
                    playerVC.willMove(toParent: nil)
                    playerVC.view.removeFromSuperview()
                    playerVC.removeFromParent()
                }
            } else {
                let created = AVPlayerViewController()
                created.showsPlaybackControls = true
                created.player = player
                hostingBox?.playerViewController = created
                hostingBox?.currentPlayer = player
                playerVC = created
            }

            playerVC.view.backgroundColor = .clear
            playerVC.view.translatesAutoresizingMaskIntoConstraints = false
            if playerVC.parent !== containerVC {
                containerVC.addChild(playerVC)
                containerVC.view.addSubview(playerVC.view)
                NSLayoutConstraint.activate([
                    playerVC.view.topAnchor.constraint(equalTo: containerVC.view.topAnchor),
                    playerVC.view.bottomAnchor.constraint(equalTo: containerVC.view.bottomAnchor),
                    playerVC.view.leadingAnchor.constraint(equalTo: containerVC.view.leadingAnchor),
                    playerVC.view.trailingAnchor.constraint(equalTo: containerVC.view.trailingAnchor)
                ])
                playerVC.didMove(toParent: containerVC)
            }
            self.playerViewController = playerVC

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
            pinch.delegate = self
            pinch.cancelsTouchesInView = false
            containerVC.view.addGestureRecognizer(pinch)
            self.pinchRecognizer = pinch

            containerVC.onHierarchyChanged = { [weak self] in
                self?.refreshNativeFullScreenButton()
            }

            setupPlayerObservers(for: player)
            refreshNativeFullScreenButton()
        }

        func update(
            player: AVPlayer,
            isFullScreen: Bool,
            onToggleFullScreen: (() -> Void)?,
            onPinchToExitFullScreen: (() -> Void)?
        ) {
            guard !isDismantled else { return }
            self.onToggleFullScreen = onToggleFullScreen
            self.onPinchToExitFullScreen = onPinchToExitFullScreen
            if currentIsFullScreen != isFullScreen {
                currentIsFullScreen = isFullScreen
            }
            if currentPlayer !== player {
                currentPlayer = player
                playerViewController?.player = player
                hostingBox?.currentPlayer = player
                discoveryRetryCount = 0
                setupPlayerObservers(for: player)
            }
            refreshNativeFullScreenButton()
        }

        func dismantle() {
            isDismantled = true
            discoveryTask?.cancel()
            discoveryTask = nil
            if let pinchRecognizer, let view = pinchRecognizer.view {
                view.removeGestureRecognizer(pinchRecognizer)
            }
            pinchRecognizer = nil
            onToggleFullScreen = nil
            onPinchToExitFullScreen = nil
            buttonObservations.removeAll()
            observedFullScreenButton = nil
            playerObservations.removeAll()
            containerVC?.onHierarchyChanged = nil
            // Only detach if a new host hasn't already claimed the shared AVPlayerViewController
            if let playerVC = playerViewController, let containerVC, playerVC.parent === containerVC {
                playerVC.willMove(toParent: nil)
                playerVC.view.removeFromSuperview()
                playerVC.removeFromParent()
            }
        }

        @objc private func handleNativeFullScreenTap() {
            onToggleFullScreen?()
        }

        @objc private func handlePinchGesture(_ recognizer: UIPinchGestureRecognizer) {
            guard currentIsFullScreen == true else { return }
            switch recognizer.state {
            case .began:
                didTriggerPinchExit = false
            case .changed:
                if !didTriggerPinchExit && recognizer.scale <= 0.84 {
                    didTriggerPinchExit = true
                    onPinchToExitFullScreen?()
                }
            case .ended:
                if !didTriggerPinchExit && recognizer.scale <= 0.90 {
                    didTriggerPinchExit = true
                    onPinchToExitFullScreen?()
                }
                didTriggerPinchExit = false
            case .cancelled, .failed:
                didTriggerPinchExit = false
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        private func setupPlayerObservers(for player: AVPlayer) {
            playerObservations.removeAll()
            playerObservations.append(
                player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        self?.refreshNativeFullScreenButton()
                    }
                }
            )
            playerObservations.append(
                player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
                    Task { @MainActor [weak self] in
                        self?.observeCurrentItem(of: player)
                        self?.refreshNativeFullScreenButton()
                    }
                }
            )
            observeCurrentItem(of: player)
        }

        private func observeCurrentItem(of player: AVPlayer) {
            if playerObservations.count > 2 {
                playerObservations.removeSubrange(2...)
            }
            guard let item = player.currentItem else { return }
            playerObservations.append(
                item.observe(\.status, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        self?.refreshNativeFullScreenButton()
                    }
                }
            )
        }

        private func findNativeFullScreenButton(in view: UIView, ignoring excludedView: UIView?) -> UIControl? {
            if let excludedView, view === excludedView {
                return nil
            }
            if let control = view as? UIControl, control.accessibilityIdentifier == "Fullscreen Button" {
                return control
            }
            for subview in view.subviews {
                if let found = findNativeFullScreenButton(in: subview, ignoring: excludedView) {
                    return found
                }
            }
            return nil
        }

        private func findIconImageView(in view: UIView) -> UIImageView? {
            if let imageView = view as? UIImageView {
                return imageView
            }
            for subview in view.subviews {
                if let found = findIconImageView(in: subview) {
                    return found
                }
            }
            return nil
        }

        private func scheduleDiscoveryRetryIfNeeded() {
            guard !isDismantled, discoveryRetryCount < 30 else { return }
            guard discoveryTask == nil else { return }
            discoveryRetryCount += 1
            discoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled, !self.isDismantled else { return }
                self.discoveryTask = nil
                self.refreshNativeFullScreenButton()
            }
        }

        private func refreshNativeFullScreenButton() {
            guard !isDismantled, let playerVC = playerViewController else {
                scheduleDiscoveryRetryIfNeeded()
                return
            }
            guard let button = findNativeFullScreenButton(in: playerVC.view, ignoring: playerVC.contentOverlayView) else {
                scheduleDiscoveryRetryIfNeeded()
                return
            }

            if observedFullScreenButton !== button {
                observedFullScreenButton = button
                buttonObservations.removeAll()
                buttonObservations.append(
                    button.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in
                            self?.refreshNativeFullScreenButton()
                        }
                    }
                )
                buttonObservations.append(
                    button.observe(\.alpha, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in
                            self?.refreshNativeFullScreenButton()
                        }
                    }
                )
                if let iconView = findIconImageView(in: button) {
                    buttonObservations.append(
                        iconView.observe(\.image, options: [.new]) { [weak self] _, _ in
                            Task { @MainActor [weak self] in
                                self?.refreshNativeFullScreenButton()
                            }
                        }
                    )
                }
            }

            configureNativeFullScreenButton(button)
        }

        /// Replaces AVPlayerViewController's default modal full-screen action with our hero toggle and keeps the icon synced.
        private func configureNativeFullScreenButton(_ button: UIControl) {
            guard !isConfiguringButton else { return }
            isConfiguringButton = true
            defer { isConfiguringButton = false }

            for target in button.allTargets {
                let targetObj = target as AnyObject
                if targetObj !== self {
                    button.removeTarget(target, action: nil, for: .allEvents)
                }
            }
            let registered = button.actions(forTarget: self, forControlEvent: .touchUpInside) ?? []
            if !registered.contains(NSStringFromSelector(#selector(handleNativeFullScreenTap))) {
                button.addTarget(self, action: #selector(handleNativeFullScreenTap), for: .touchUpInside)
            }

            let isExpanded = (currentIsFullScreen == true)
            let symbolName = isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            let expectedLabel = isExpanded ? "exit full screen" : "enter full screen"
            if button.accessibilityLabel != expectedLabel {
                button.accessibilityLabel = expectedLabel
            }

            if let iconView = findIconImageView(in: button), iconView.accessibilityIdentifier != symbolName {
                let updatedImage = UIImage(systemName: symbolName, withConfiguration: iconView.image?.symbolConfiguration)
                iconView.image = updatedImage
                iconView.accessibilityIdentifier = symbolName
                if let uiButton = button as? UIButton {
                    uiButton.setImage(updatedImage, for: .normal)
                }
            }
        }
    }
}
