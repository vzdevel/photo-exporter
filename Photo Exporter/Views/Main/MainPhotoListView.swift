//
//  MainPhotoListView.swift
//  Photo Exporter
//

import SwiftUI
import Photos

struct MainPhotoListView: View {
    @StateObject private var viewModel = PhotoListViewModel()
    @State private var selectedPhotoForDetail: PhotoItem? = nil
    @State private var isShowingRefreshConfirmation: Bool = false
    @State private var justLongPressed: Bool = false
    @State private var committedSearchQuery: String = ""
    @State private var isSearchActive: Bool = false
    @State private var currentMatchedID: String? = nil
    @State private var matchedIDs: [String] = []
    @State private var currentMatchIndex: Int = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Filter Chips Bar
                    if viewModel.currentMediaSource.isFolder || viewModel.authorizationStatus == .authorized || viewModel.authorizationStatus == .limited {
                        FilterBarView(
                            selectedFilter: $viewModel.selectedFilter,
                            selectedMediaType: $viewModel.selectedMediaType,
                            counts: viewModel.filterCounts,
                            isSearchActive: $isSearchActive,
                            matchedCount: matchedIDs.count,
                            currentMatchIndex: currentMatchIndex,
                            onSearchQueryChanged: { query in
                                committedSearchQuery = query
                            },
                            onNextMatch: {
                                if currentMatchIndex < matchedIDs.count - 1 {
                                    currentMatchIndex += 1
                                }
                            },
                            onPreviousMatch: {
                                if currentMatchIndex > 0 {
                                    currentMatchIndex -= 1
                                }
                            }
                        )
                        Divider()
                    }

                    // Folder Breadcrumb Path Bar
                    if viewModel.currentMediaSource.isFolder && !viewModel.displayedPathSegments.isEmpty {
                        FolderPathBarView(
                            segments: viewModel.displayedPathSegments,
                            activeCount: viewModel.activePathSegmentCount,
                            revealRequest: viewModel.pathBarRevealRequest,
                            onSelectSegment: { index in
                                viewModel.navigateToPathSegment(at: index)
                            }
                        )
                        Divider()
                    }

                    // Content View
                    contentView
                }

                // Bottom Floating Controls (Selection Toolbar sits cleanly above the single persistent progress banner)
                VStack(spacing: 6) {
                    if viewModel.isSelectionMode {
                        SelectionToolbarView(
                            selectedCount: viewModel.selectedPhotoIDs.count,
                            totalVisibleCount: viewModel.filteredPhotos.count,
                            isExportDisabled: viewModel.isExportDisabled,
                            showsApplyAction: viewModel.shouldShowApplyButton,
                            isRangeSelectionMode: $viewModel.isRangeSelectionMode,
                            onSelectAll: { viewModel.selectAll() },
                            onDeselectAll: { viewModel.deselectAll() },
                            onBatchEditDateTime: { viewModel.isShowingBatchDateTimeSheet = true },
                            onDelete: { viewModel.deleteSelectedPhotos() },
                            onExport: { viewModel.initiateExport() }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))

                        FloatingBannerBottomSpacer(coordinator: viewModel.progressCoordinator)
                    }
                }
                .padding(.bottom, 6)
            }
            .navigationTitle(viewModel.currentMediaSource.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    // Chronological Sort Order Toggle (composed icon: list.bullet + up/down arrow)
                    Button {
                        viewModel.isChronologicalAscending.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 14, weight: .semibold))
                            Image(systemName: viewModel.isChronologicalAscending ? "arrow.up" : "arrow.down")
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                    .accessibilityLabel(viewModel.isChronologicalAscending ? "Sort Oldest First" : "Sort Newest First")
                }

                ToolbarItem(placement: .principal) {
                    Button {
                        viewModel.isShowingMediaSourceSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            AppSourceIconView(
                                iconName: viewModel.currentMediaSource.iconName,
                                isAssetImage: viewModel.currentMediaSource.isAssetIcon,
                                size: viewModel.currentMediaSource.isAssetIcon ? 18 : 12,
                                weight: .semibold,
                                color: viewModel.currentMediaSource.iconColor
                            )
                            Text(viewModel.currentMediaSource.navigationTitle)
                                .font(.headline)
                                .lineLimit(1)
                                .foregroundColor(.primary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityLabel("Switch Media Source")
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if viewModel.currentMediaSource.isFolder || viewModel.authorizationStatus == .authorized || viewModel.authorizationStatus == .limited {
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                viewModel.isSelectionMode.toggle()
                            }
                        } label: {
                            if viewModel.isSelectionMode {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                            } else {
                                Text("Select")
                                    .font(.system(.body, weight: .semibold))
                            }
                        }
                    }
                }
            }
            .navigationDestination(item: $selectedPhotoForDetail) { item in
                PhotoDetailView(
                    item: item,
                    items: viewModel.filteredPhotos,
                    listViewModel: viewModel,
                    mediaSource: viewModel.currentMediaSource,
                    isExportDisabled: viewModel.isExportDisabled,
                    onDateAdjusted: { assetID, newDate, tz, isAdjusted in
                        viewModel.updatePhotoAdjustment(
                            assetID: assetID,
                            newDate: newDate,
                            timeZone: tz,
                            isAdjusted: isAdjusted
                        )
                    },
                    onMetadataRefreshed: { assetID, metadata in
                        viewModel.updateSinglePhotoMetadata(
                            assetID: assetID,
                            metadata: metadata
                        )
                    },
                    onFilenameChanged: { assetID, newFilename in
                        viewModel.updatePhotoFilename(
                            assetID: assetID,
                            newFilename: newFilename
                        )
                    },
                    onFolderItemUpdated: { oldID, updatedItem in
                        viewModel.updateFolderItem(oldID: oldID, updatedItem: updatedItem)
                    },
                    onDeleted: { assetID in
                        viewModel.removeDeletedPhoto(assetID: assetID)
                        if !viewModel.currentMediaSource.isFolder {
                            viewModel.loadPhotos()
                        }
                    }
                )
                .id(item.id)
            }
            .sheet(isPresented: $viewModel.isShowingMediaSourceSheet) {
                MediaSourceSheet(
                    currentSource: viewModel.currentMediaSource,
                    onSelectSource: { source in
                        viewModel.isShowingMediaSourceSheet = false
                        viewModel.switchMediaSource(to: source)
                    },
                    onCancel: {
                        viewModel.isShowingMediaSourceSheet = false
                    }
                )
            }
            .sheet(isPresented: $viewModel.isShowingAnalysisSheet) {
                AnalysisProgressContainerView(
                    coordinator: viewModel.progressCoordinator,
                    mediaSource: viewModel.currentMediaSource,
                    onDismiss: {
                        viewModel.isShowingAnalysisSheet = false
                        viewModel.handleAnalysisSheetDismissed()
                    },
                    onRetryFailed: { failedItems in
                        viewModel.retryFailedAnalysis(items: failedItems)
                    }
                )
            }
            .onChange(of: viewModel.isShowingAnalysisSheet) { _, isShowing in
                if !isShowing {
                    viewModel.handleAnalysisSheetDismissed()
                }
            }
            .sheet(isPresented: $viewModel.isShowingBatchDateTimeSheet) {
                BatchEditDateTimeSheet(
                    selectedCount: viewModel.selectedPhotoIDs.count,
                    initialDate: viewModel.selectedItems.first?.creationDate ?? Date(),
                    initialTimeZone: viewModel.selectedItems.first?.timeZone ?? .current,
                    onApply: { date, stepSeconds, tz in
                        Task {
                            await viewModel.batchUpdateDateTime(
                                newStartingDate: date,
                                stepSeconds: stepSeconds,
                                newTimeZone: tz
                            )
                        }
                    }
                )
            }
            .alert("Notice", isPresented: $viewModel.isShowingErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "An unexpected error occurred.")
            }
            .alert(
                "Delete \(viewModel.pendingFolderDeleteItems.count == 1 ? "File" : "\(viewModel.pendingFolderDeleteItems.count) Files")?",
                isPresented: $viewModel.isShowingFolderDeleteConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    viewModel.pendingFolderDeleteItems = []
                }
                Button("Delete", role: .destructive) {
                    viewModel.confirmDeleteSelectedFolderItems()
                }
            } message: {
                let count = viewModel.pendingFolderDeleteItems.count
                if count == 1, let first = viewModel.pendingFolderDeleteItems.first {
                    Text("This will permanently delete \"\(first.filename)\" from \(viewModel.currentMediaSource.navigationTitle).")
                } else {
                    Text("This will permanently delete \(count) files from \(viewModel.currentMediaSource.navigationTitle).")
                }
            }
            .alert(
                "Delete Folder?",
                isPresented: $viewModel.isShowingFolderDirectoryDeleteConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    viewModel.pendingFolderDirectoryDelete = nil
                }
                Button("Delete", role: .destructive) {
                    viewModel.confirmDeleteFolderDirectory()
                }
            } message: {
                if let folder = viewModel.pendingFolderDirectoryDelete {
                    Text("This will permanently delete folder \"\(folder.name)\" and all of its contents from \(viewModel.currentMediaSource.navigationTitle).")
                } else {
                    Text("This will permanently delete the selected folder and all of its contents.")
                }
            }
            .alert(
                "Refresh Photos",
                isPresented: $isShowingRefreshConfirmation
            ) {
                Button("Reload & Analyze New") {
                    viewModel.loadPhotos(forceReload: false, isUserTriggeredReload: true)
                }
                Button("Reload & Re-analyze All") {
                    viewModel.loadPhotos(forceReload: true, isUserTriggeredReload: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose \"Reload & Analyze New\" to reload photos and analyze newly added or modified photos, or \"Reload & Re-analyze All\" to inspect all photo metadata from scratch.")
            }
            .onAppear {
                if viewModel.allPhotos.isEmpty && !viewModel.isLoading && (viewModel.currentMediaSource.isFolder || viewModel.authorizationStatus == .authorized || viewModel.authorizationStatus == .limited) {
                    viewModel.loadPhotos()
                }
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active && !viewModel.isLoading && !viewModel.allPhotos.isEmpty {
                    viewModel.refreshIfCacheExpired()
                } else if newPhase == .background {
                    MetadataCacheService.shared.flushSync()
                }
            }
        }
        .overlay(alignment: .bottom) {
            FloatingProgressBannerContainerView(
                coordinator: viewModel.progressCoordinator,
                isLoading: viewModel.isLoading,
                isAnalyzing: viewModel.isAnalyzing,
                hasUnanalyzed: { viewModel.hasUnanalyzedPhotos },
                onOpenAnalysisSheet: {
                    viewModel.isShowingAnalysisSheet = true
                },
                onOpenExportSheet: {
                    viewModel.isShowingExportProgress = true
                }
            )
            .padding(.bottom, 6)
        }
        .sheet(isPresented: $viewModel.isShowingDestinationSheet) {
            ExportDestinationSheet(
                itemCount: viewModel.effectiveExportItems.count,
                showProcessingInfo: !viewModel.currentMediaSource.isFolder,
                renameGroups: viewModel.pendingExportRenameGroups,
                onSelectLocal: {
                    viewModel.handleSelectLocalDestination()
                },
                onSelectGoogleDrive: { account in
                    viewModel.handleSelectGoogleDriveDestination(account: account)
                },
                onSelectGooglePhotos: { account in
                    viewModel.handleSelectGooglePhotosDestination(account: account)
                },
                onSelectSamba: { destination in
                    viewModel.handleSelectSambaDestination(destination: destination)
                },
                onCancel: {
                    viewModel.handleDestinationPickerCancelled()
                }
            )
        }
        .sheet(isPresented: $viewModel.isShowingFolderPicker) {
            FolderPicker(
                onFolderPicked: { folderURL in
                    viewModel.handleFolderSelected(folderURL: folderURL)
                },
                onCancel: {
                    viewModel.handleFolderPickerCancelled()
                }
            )
        }
        .sheet(isPresented: $viewModel.isShowingExportSummary) {
            if let target = viewModel.pendingExportTarget {
                ExportSummarySheet(
                    target: target,
                    rawItems: viewModel.activeExportSummaryItems,
                    mediaSource: viewModel.currentMediaSource,
                    onConfirmExport: { resolvedItems in
                        viewModel.handleConfirmExportSummary(resolvedItems: resolvedItems)
                    },
                    onCancel: {
                        viewModel.handleCancelExportSummary()
                    }
                )
            }
        }
        .sheet(isPresented: $viewModel.isShowingApplySummarySheet) {
            ApplyChangesSummarySheet(
                items: viewModel.activeApplySummaryItems,
                mediaSource: viewModel.currentMediaSource,
                onConfirmApply: { itemsToApply in
                    viewModel.startApplyChangesInPlace(items: itemsToApply)
                },
                onCancel: {
                    viewModel.isShowingApplySummarySheet = false
                    viewModel.explicitExportSourceItems = nil
                }
            )
        }
        .sheet(isPresented: $viewModel.isShowingExportProgress) {
            ExportProgressContainerView(
                coordinator: viewModel.progressCoordinator,
                mediaSource: viewModel.currentMediaSource,
                onCancel: { viewModel.cancelExport() },
                onDismiss: {
                    viewModel.isShowingExportProgress = false
                    viewModel.handleExportSheetDismissed()
                },
                onResume: { viewModel.resumeExport() },
                onFinish: { viewModel.finishExport() },
                onRetryFailed: { failedItems in
                    viewModel.retryFailedExports(items: failedItems)
                }
            )
        }
        .onChange(of: viewModel.isShowingExportProgress) { _, isShowing in
            if !isShowing {
                viewModel.handleExportSheetDismissed()
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var contentView: some View {
        if viewModel.currentMediaSource.isFolder {
            if viewModel.filteredPhotos.isEmpty && viewModel.childFolders.isEmpty && !viewModel.isLoading {
                emptyStateView
            } else {
                photoListView
            }
        } else {
            switch viewModel.authorizationStatus {
            case .authorized, .limited:
                if viewModel.filteredPhotos.isEmpty && !viewModel.isLoading {
                    emptyStateView
                } else {
                    photoListView
                }

            case .denied, .restricted:
                permissionDeniedView

            case .notDetermined:
                requestPermissionView

            @unknown default:
                requestPermissionView
            }
        }
    }

    private var photoListView: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    if viewModel.currentMediaSource.isFolder {
                        ForEach(viewModel.childFolders) { folder in
                            Button {
                                viewModel.openSubfolder(folder)
                            } label: {
                                FolderRowView(folder: folder)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if !viewModel.isSelectionMode && folder.isDeletable {
                                    Button(role: .destructive) {
                                        viewModel.requestDeleteFolder(folder)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        }
                    }

                    ForEach(viewModel.filteredPhotos) { item in
                        let isSelected = viewModel.selectedPhotoIDs.contains(item.id)
                        let isLast = viewModel.lastSelectedID == item.id
                        let isMatched = currentMatchedID == item.id

                        Button {
                            if justLongPressed {
                                justLongPressed = false
                                return
                            }
                            if viewModel.isSelectionMode {
                                viewModel.toggleSelection(for: item)
                            } else {
                                selectedPhotoForDetail = item
                            }
                        } label: {
                            PhotoRowView(
                                item: item,
                                isSelected: isSelected,
                                isSelectionMode: viewModel.isSelectionMode,
                                isRangeSelectionMode: viewModel.isRangeSelectionMode,
                                isLastSelected: isLast,
                                mediaSource: viewModel.currentMediaSource,
                                onSelectRangeToHere: {
                                    viewModel.selectRangeToHere(item: item)
                                }
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isMatched ? Color.yellow.opacity(0.18) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isMatched ? Color.yellow.opacity(0.7) : Color.clear, lineWidth: 1.5)
                        )
                        .id(item.id)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.45)
                                .onEnded { _ in
                                    guard !viewModel.isSelectionMode else { return }
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    justLongPressed = true
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                        viewModel.isSelectionMode = true
                                        viewModel.selectedPhotoIDs = [item.id]
                                        viewModel.lastSelectedID = item.id
                                    }
                                }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !viewModel.isSelectionMode {
                                Button(role: .destructive) {
                                    viewModel.deleteSinglePhoto(item: item)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    }

                    // Bottom spacer so photos scroll under the semi-transparent bottom bars
                    let bottomSpacerHeight: CGFloat = {
                        if viewModel.isSelectionMode && viewModel.progressStatus.isVisible {
                            return 155
                        } else if viewModel.isSelectionMode {
                            return 100
                        } else if viewModel.progressStatus.isVisible {
                            return 60
                        } else {
                            return 0
                        }
                    }()

                    if bottomSpacerHeight > 0 {
                        Color.clear
                            .frame(height: bottomSpacerHeight)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                // Allow the pull-to-refresh spinner and drag gesture to complete
                try? await Task.sleep(nanoseconds: 100_000_000)
                // Schedule the confirmation dialog once the scroll view has animated back to rest
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    isShowingRefreshConfirmation = true
                }
            }
            .onChange(of: committedSearchQuery) { newQuery in
                performSearch(query: newQuery, scrollProxy: proxy)
            }
            .onChange(of: viewModel.filteredPhotos) { _ in
                if isSearchActive && !committedSearchQuery.isEmpty {
                    performSearch(query: committedSearchQuery, scrollProxy: proxy)
                }
            }
            .onChange(of: isSearchActive) { active in
                if !active {
                    committedSearchQuery = ""
                    matchedIDs = []
                    currentMatchedID = nil
                    currentMatchIndex = 0
                }
            }
            .onChange(of: currentMatchIndex) { newIndex in
                guard newIndex >= 0 && newIndex < matchedIDs.count else { return }
                let targetID = matchedIDs[newIndex]
                currentMatchedID = targetID
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(targetID, anchor: .top)
                }
            }
        }
    }

    private func performSearch(query: String, scrollProxy: ScrollViewProxy) {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else {
            matchedIDs = []
            currentMatchedID = nil
            currentMatchIndex = 0
            return
        }

        let dateCriteria = DateQueryCriteria.parse(from: cleanQuery)
        let matches = viewModel.filteredPhotos.filter {
            $0.matchesSearch(query: cleanQuery, dateCriteria: dateCriteria)
        }

        matchedIDs = matches.map(\.id)
        currentMatchIndex = 0

        if let firstMatch = matches.first {
            currentMatchedID = firstMatch.id
            withAnimation(.easeInOut(duration: 0.25)) {
                scrollProxy.scrollTo(firstMatch.id, anchor: .top)
            }
        } else {
            currentMatchedID = nil
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: viewModel.selectedFilter.iconName ?? "slider.horizontal.3")
                .font(.system(size: 48))
                .foregroundColor(viewModel.selectedFilter.color)

            Text("No Photos Found")
                .font(.headline)

            Text(viewModel.selectedFilter.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var requestPermissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundColor(.blue)

            Text("Photo Library Access")
                .font(.title2.weight(.bold))

            Text("Photo Exporter needs permission to access your photo library to display files chronologically, analyze EXIF timestamps, and export or delete photos.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                viewModel.requestAccess()
            } label: {
                Text("Allow Access")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Photo Library Access Denied")
                .font(.headline)

            Text("Please enable Photo Library access in Settings to view and export your photos.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Isolated Progress Containers (Decoupled from Main List View)

struct FloatingBannerBottomSpacer: View {
    @ObservedObject var coordinator: ProgressCoordinator
    var visibleHeight: CGFloat = 54

    var body: some View {
        if coordinator.progressStatus.isVisible {
            Color.clear
                .frame(height: visibleHeight)
                .allowsHitTesting(false)
        }
    }
}

struct FloatingProgressBannerContainerView: View {
    @ObservedObject var coordinator: ProgressCoordinator
    var isLoading: Bool
    var isAnalyzing: Bool
    var hasUnanalyzed: () -> Bool
    var onOpenAnalysisSheet: () -> Void
    var onOpenExportSheet: () -> Void

    var body: some View {
        if coordinator.progressStatus.isVisible {
            FloatingProgressBannerView(status: coordinator.progressStatus) {
                if coordinator.exportProgress.isExporting ||
                    coordinator.exportProgress.isInterrupted ||
                    coordinator.exportProgress.isCancelled ||
                    (coordinator.exportProgress.isCompleted && coordinator.exportProgress.hasErrors) {
                    onOpenExportSheet()
                    return
                }
                guard !isLoading else { return }
                if isAnalyzing || !coordinator.analysisProgress.failedItems.isEmpty || hasUnanalyzed() {
                    onOpenAnalysisSheet()
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct ExportProgressContainerView: View {
    @ObservedObject var coordinator: ProgressCoordinator
    var mediaSource: MediaSource = .photoLibrary
    let onCancel: () -> Void
    let onDismiss: () -> Void
    var onResume: (() -> Void)? = nil
    let onFinish: () -> Void
    var onRetryFailed: (([PhotoItem]) -> Void)? = nil

    var body: some View {
        ExportProgressView(
            progress: $coordinator.exportProgress,
            mediaSource: mediaSource,
            onCancel: onCancel,
            onDismiss: onDismiss,
            onResume: onResume,
            onFinish: onFinish,
            onRetryFailed: onRetryFailed
        )
    }
}

private struct AnalysisProgressContainerView: View {
    @ObservedObject var coordinator: ProgressCoordinator
    var mediaSource: MediaSource = .photoLibrary
    let onDismiss: () -> Void
    var onRetryFailed: (([PhotoItem]) -> Void)? = nil

    var body: some View {
        AnalysisProgressView(
            progress: $coordinator.analysisProgress,
            mediaSource: mediaSource,
            onDismiss: onDismiss,
            onRetryFailed: onRetryFailed
        )
    }
}
