//
//  ExportProgress.swift
//  Photo Exporter
//

import Foundation
import AVFoundation

struct ExportProgress: Equatable {
    var isExporting: Bool = false
    var totalCount: Int = 0
    var currentItemIndex: Int = 0
    var currentFilename: String = ""
    var currentItem: PhotoItem? = nil
    var successCount: Int = 0
    var failureCount: Int = 0
    var destinationURL: URL? = nil
    var errorMessages: [String] = []
    var failedItems: [PhotoItem] = []
    var successfulItems: [PhotoItem] = []
    var isCancelled: Bool = false
    var isInterrupted: Bool = false
    var isCompleted: Bool = false
    var currentItemProgress: Double = 0.0
    var backgroundItemProgress: Double = 0.0
    var updatedFileSizes: [String: Int64] = [:]
    var isApplyInPlace: Bool = false

    var fractionCompleted: Double {
        guard totalCount > 0 else { return 0.0 }
        let inFlight = isExporting ? min(max(currentItemProgress, 0.0), 0.999) : 0.0
        return min(1.0, (Double(successCount) + inFlight) / Double(totalCount))
    }

    var percentageString: String {
        let percent = Int(fractionCompleted * 100)
        return "\(percent)%"
    }

    var hasErrors: Bool {
        failureCount > 0 || !errorMessages.isEmpty
    }

    var statusSummary: String {
        if isApplyInPlace {
            if isInterrupted {
                return "Apply paused (\(successCount) of \(totalCount) updated)"
            }
            if isCancelled {
                return "Apply cancelled (\(successCount) of \(totalCount) updated)"
            }
            if isCompleted {
                let itemStr = successCount == 1 ? "item" : "items"
                if hasErrors {
                    if successCount == 0 {
                        let count = failureCount > 0 ? failureCount : totalCount
                        let errItemStr = count == 1 ? "item" : "items"
                        return "Apply failed (\(count) \(errItemStr))"
                    } else {
                        return "Updated \(successCount) \(itemStr) with \(failureCount) errors"
                    }
                } else {
                    return "Successfully applied changes to \(successCount) \(itemStr)"
                }
            }
            if isExporting {
                return "Applying changes \(currentItemIndex) of \(totalCount)..."
            }
            return "Ready to apply"
        }

        if isInterrupted {
            return "Export paused (\(successCount) of \(totalCount) exported)"
        }
        if isCancelled {
            return "Export cancelled (\(successCount) of \(totalCount) exported)"
        }
        if isCompleted {
            let itemStr = successCount == 1 ? "item" : "items"
            if hasErrors {
                if successCount == 0 {
                    let count = failureCount > 0 ? failureCount : totalCount
                    let errItemStr = count == 1 ? "item" : "items"
                    return "Export failed (\(count) \(errItemStr))"
                } else {
                    return "Exported \(successCount) \(itemStr) with \(failureCount) errors"
                }
            } else {
                return "Successfully exported \(successCount) \(itemStr)"
            }
        }
        if isExporting {
            return "Exporting \(currentItemIndex) of \(totalCount)..."
        }
        return "Ready to export"
    }
}

/// Checks if an error is due to a broken/disconnected socket or lost network connection that requires session re-establishment
func isBrokenConnectionError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == "Network.NWError" || nsError.domain.contains("NWError") {
        return true
    }
    if nsError.domain == "SMB2Client" {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("frame length") ||
           lower.contains("closed unexpectedly") ||
           lower.contains("timed out") ||
           lower.contains("timeout") ||
           lower.contains("keep-alive") ||
           lower.contains("parse") ||
           lower.contains("truncated") ||
           lower.contains("broken") ||
           lower.contains("session") ||
           lower.contains("disconnected") ||
           lower.contains("connection") ||
           lower.contains("socket") {
            return true
        }
    }
    if nsError.domain == NSPOSIXErrorDomain {
        switch nsError.code {
        case Int(ENOTCONN), // 57 - Socket is not connected
             Int(ECONNRESET), // 54 - Connection reset by peer
             Int(ECONNABORTED), // 53 - Software caused connection abort
             Int(EPIPE), // 32 - Broken pipe
             Int(ETIMEDOUT), // 60 - Operation timed out
             Int(ENETDOWN), // 50 - Network is down
             Int(ENETUNREACH), // 51 - Network is unreachable
             Int(EHOSTUNREACH), // 65 - No route to host
             Int(EHOSTDOWN): // 64 - Host is down
            return true
        default:
            break
        }
    }
    let lower = error.localizedDescription.lowercased()
    return lower.contains("socket is not connected") ||
           lower.contains("not connected") ||
           lower.contains("enotconn") ||
           lower.contains("error 57") ||
           lower.contains("broken pipe") ||
           lower.contains("connection reset") ||
           lower.contains("connection closed") ||
           lower.contains("connection lost") ||
           lower.contains("network connection was lost") ||
           lower.contains("network.nwerror") ||
           lower.contains("connection refused") ||
           lower.contains("invalid smb frame length") ||
           lower.contains("frame length") ||
           lower.contains("smb response") ||
           lower.contains("unexpectedly by server") ||
           lower.contains("timed out waiting for smb") ||
           lower.contains("keep-alive")
}

/// Checks if an export/upload failure is caused by a transient/retryable network, media export, or I/O condition
func isRetryableExportError(_ error: Error) -> Bool {
    if isBrokenConnectionError(error) {
        return true
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorCallIsActive,
             NSURLErrorDataNotAllowed,
             NSURLErrorResourceUnavailable:
            return true
        default:
            break
        }
    }
    if nsError.domain == AVFoundationErrorDomain {
        return true
    }
    if nsError.domain == "ExifMetadataService" {
        return true
    }
    if let cocoaError = error as? CocoaError {
        if cocoaError.code == .fileLocking || cocoaError.code == .fileWriteUnknown {
            return true
        }
    }
    if let statusCode = nsError.userInfo["HTTPStatusCode"] as? Int, (statusCode == 429 || statusCode >= 500) {
        return true
    }
    let lower = error.localizedDescription.lowercased()
    return lower.contains("timed out") ||
           lower.contains("timeout") ||
           lower.contains("rate limit") ||
           lower.contains("too many requests") ||
           lower.contains("export failed") ||
           lower.contains("operation interrupted") ||
           lower.contains("media services were reset") ||
           lower.contains("resource busy") ||
           lower.contains("could not be completed") ||
           lower.contains("503") ||
           lower.contains("502") ||
           lower.contains("500") ||
           lower.contains("429") ||
           lower.contains("temporarily unavailable")
}
