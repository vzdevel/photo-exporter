//
//  BackgroundExportManager.swift
//  Photo Exporter
//
//  Manages BGContinuedProcessingTask registration, submission, progress updates,
//  and expiration handling so media exports continue when switching apps.
//

import Foundation
import BackgroundTasks

@MainActor
final class BackgroundExportManager {
    static let shared = BackgroundExportManager()

    private static let bundleIdentifierPrefix = Bundle.main.bundleIdentifier ?? "com.example.Photo-Exporter"
    static let taskIdentifierPattern = "\(bundleIdentifierPrefix).export.*"
    static let activeTaskIdentifier = "\(bundleIdentifierPrefix).export.active"

    private var isRegistered = false
    private var isExportActive = false
    private var activeTask: BGContinuedProcessingTask?
    private var submittedRequestIdentifier: String?
    private var onExpireHandler: (() -> Void)?

    private static let unitsPerItem: Int64 = 1000

    private var currentCompleted: Int = 0
    private var currentTotal: Int = 1
    private var currentItemProgress: Double = 0.0
    private var currentFilename: String = ""

    private init() {}

    /// Registers the stable continued processing task identifier once at app launch
    /// and cleans up any stale task requests from a previous killed session.
    func register() {
        guard !isRegistered else { return }
        isRegistered = true

        BGTaskScheduler.shared.cancelAllTaskRequests()

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.activeTaskIdentifier,
            using: .main
        ) { [weak self] task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated {
                self?.handleLaunchedTask(continuedTask)
            }
        }
    }

    /// Submits a BGContinuedProcessingTaskRequest when a foreground export starts.
    func beginExportTask(totalCount: Int, onExpire: @escaping () -> Void) {
        if activeTask != nil || submittedRequestIdentifier != nil {
            endExportTask(success: false)
        }
        BGTaskScheduler.shared.cancelAllTaskRequests()

        isExportActive = true
        onExpireHandler = onExpire
        currentCompleted = 0
        currentTotal = max(1, totalCount)
        currentItemProgress = 0.0
        currentFilename = ""

        let requestID = Self.activeTaskIdentifier
        let subtitle = totalCount == 1 ? "0 of 1 item" : "0 of \(totalCount) items"
        let request = BGContinuedProcessingTaskRequest(
            identifier: requestID,
            title: "Exporting Media",
            subtitle: subtitle
        )
        request.strategy = .queue

        do {
            try BGTaskScheduler.shared.submit(request)
            submittedRequestIdentifier = requestID
        } catch {
            print("Failed to submit BGContinuedProcessingTaskRequest: \(error.localizedDescription)")
            submittedRequestIdentifier = nil
        }
    }

    /// Updates NSProgress and Live Activity title/subtitle for the active background task.
    func updateProgress(completed: Int, total: Int, currentItemProgress: Double = 0.0, currentFilename: String) {
        let clampedTotal = max(1, total)
        let clampedItemProgress = min(max(currentItemProgress, 0.0), 1.0)
        guard completed != currentCompleted ||
              clampedTotal != currentTotal ||
              clampedItemProgress != self.currentItemProgress ||
              currentFilename != self.currentFilename else {
            return
        }

        currentCompleted = completed
        currentTotal = clampedTotal
        self.currentItemProgress = clampedItemProgress
        self.currentFilename = currentFilename

        guard let task = activeTask else { return }
        applyProgress(to: task)
    }

    /// Marks the active BGContinuedProcessingTask completed or cancels any pending request.
    func endExportTask(success: Bool) {
        isExportActive = false
        onExpireHandler = nil

        if let task = activeTask {
            activeTask = nil
            submittedRequestIdentifier = nil
            task.setTaskCompleted(success: success)
        } else if let pendingID = submittedRequestIdentifier {
            submittedRequestIdentifier = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: pendingID)
        }
    }

    // MARK: - Private

    private func handleLaunchedTask(_ task: BGContinuedProcessingTask) {
        guard isExportActive else {
            task.setTaskCompleted(success: true)
            return
        }

        activeTask = task
        applyProgress(to: task)

        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let expireCallback = self.onExpireHandler
                self.activeTask = nil
                self.isExportActive = false
                self.onExpireHandler = nil
                self.submittedRequestIdentifier = nil
                expireCallback?()
                task.setTaskCompleted(success: false)
            }
        }
    }

    private func applyProgress(to task: BGContinuedProcessingTask) {
        let safeTotalItems = Int64(max(1, currentTotal))
        let safeTotalUnits = safeTotalItems * Self.unitsPerItem
        let clampedItemFraction = min(max(currentItemProgress, 0.0), 0.999)
        let itemUnits = Int64((clampedItemFraction * Double(Self.unitsPerItem)).rounded())
        let rawCompletedUnits = Int64(max(0, currentCompleted)) * Self.unitsPerItem + itemUnits
        let safeCompletedUnits = min(max(0, rawCompletedUnits), safeTotalUnits)

        task.progress.totalUnitCount = safeTotalUnits
        task.progress.completedUnitCount = safeCompletedUnits

        let countPart = "\(currentCompleted) of \(currentTotal)"
        let itemPercent = Int((min(max(currentItemProgress, 0.0), 1.0) * 100).rounded())
        let filePart: String
        if currentFilename.isEmpty {
            filePart = ""
        } else if itemPercent > 0 && currentCompleted < currentTotal {
            filePart = " • \(currentFilename) (\(itemPercent)%)"
        } else {
            filePart = " • \(currentFilename)"
        }
        task.updateTitle("Exporting Media", subtitle: "\(countPart)\(filePart)")
    }
}

