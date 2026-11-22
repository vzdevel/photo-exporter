//
//  AnalysisProgress.swift
//  Photo Exporter
//
//  Created by Antigravity on 2026-11-10.
//

import Foundation

/// Progress and state representation for photo library metadata analysis
struct AnalysisProgress {
    var isAnalyzing: Bool = false
    var isFinished: Bool = false
    var totalCount: Int = 0
    var processedCount: Int = 0
    var currentItem: PhotoItem? = nil
    var currentFilename: String = ""
    var errorMessages: [String] = []
    var failedItems: [PhotoItem] = []

    var fractionCompleted: Double {
        guard totalCount > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(processedCount) / Double(totalCount)))
    }

    var percentageString: String {
        guard totalCount > 0 else { return "0%" }
        let percent = Int((Double(processedCount) / Double(totalCount)) * 100)
        return "\(min(100, max(0, percent)))%"
    }

    var statusSummary: String {
        if isFinished {
            let failCount = max(errorMessages.count, failedItems.count)
            if failCount == 0 {
                return "All \(totalCount) items analyzed successfully"
            } else {
                return "\(processedCount) analyzed (\(failCount) unanalyzed - pending retry)"
            }
        }
        if processedCount > 0 {
            return "Analyzing metadata: \(processedCount) of \(totalCount) completed"
        }
        return "Analyzing metadata for library items..."
    }
}

