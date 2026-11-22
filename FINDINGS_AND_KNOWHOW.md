# Key Findings, Nuances & Engineering Know-How

This document captures deep technical insights, platform-specific quirks, and critical engineering findings discovered throughout the development of **Photo Exporter**. Future agents and engineers should consult this before modifying metadata or export pipelines.

---

## 1. ImageIO & Metadata Embedding

### 1.1 The File Inflation Problem (`AddImageFromSource` vs `CopyImageSource`)
- **Symptom**: Exporting a 1.2MB JPEG with adjusted date/time or GPS metadata inflated the file size to 1.7MB.
- **Root Cause**: `CGImageDestinationAddImageFromSource(destination, source, index, properties)` does **not** perform a lossless copy if properties are provided. Apple's ImageIO decodes the image DCT blocks and re-compresses them using ImageIO's default JPEG compression quality (~0.85). If the original image was saved at 0.7 or came from a messaging app/web with moderate compression, re-encoding it at 0.85 inflated the file size and caused generational compression loss.
- **Solution**: Use Apple's dedicated lossless API:
  ```swift
  let success = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error)
  ```
  `CGImageDestinationCopyImageSource` copies the compressed bitstream directly and modifies only header markers (EXIF, TIFF, GPS, XMP). The output file size changes by only the few bytes required for the metadata header tags (~1–3 KB).

### 1.2 Lossless Metadata Embedding and Vendor-Specific APP Segments (Size Reduction)
- **Symptom**: A 3.7MB JPEG (e.g. `5b0a1e3c7997c3c2c004b2bbc57b4dff.jpg` / `IMG_0045.JPG`) exported at 3.3MB despite using the lossless embedding path.
- **Root Cause**:
  1. The underlying image bitstream is **100% byte-for-byte identical** (verified by inspecting the entropy-coded scan data after `0xFFDA` SOS marker; exactly 3,087,632 bytes in both original and export). The image was **not** recompressed or degraded.
  2. The original file from certain devices (e.g. Vivo, Xiaomi) contained ~454 KB of non-standard proprietary computational/debug markers in JPEG application segments `APP5` through `APP11` (`0xFFE5`–`0xFFEB`), such as `vivoawb`, `vivoaf`, `vivoAECA`.
  3. When `CGImageDestinationCopyImageSource` rebuilds standard EXIF (`APP1`) and ICC (`APP2`) metadata, ImageIO intentionally strips non-standardized vendor diagnostic markers from the JPEG header. This cleanly sheds ~450 KB of raw camera debug data while keeping full visual image fidelity losslessly intact.

### 1.3 PNG Metadata Discrepancy (Simulator vs. Physical iOS Device)
- **Symptom**: On the iOS Simulator, Date/Time Original appeared correctly in exported PNG files. On a physical iPhone, Date/Time Original was completely missing, while `OffsetTimeOriginal` was set correctly.
- **Underlying Reason**:
  1. PNG has no native binary EXIF segment like JPEG (`APP1` IFD). All EXIF metadata in PNG is serialized as **XMP XML within an `iTXt` chunk** (`XML:com.adobe.xmp`).
  2. Apple's high-level `CGImageMetadataSetValueMatchingImageProperty` maps `kCGImagePropertyExifDateTimeOriginal` to `xmp:CreateDate` and `photoshop:DateCreated`, but **does not output an explicit `exif:DateTimeOriginal` tag** in `xmlns:exif="http://ns.adobe.com/exif/1.0/"`.
  3. **Simulator (macOS host runtime)**: Contains a desktop fallback layer in ImageIO that reads `photoshop:DateCreated` or `xmp:CreateDate` when reading PNG metadata and synthesizes `{Exif}.DateTimeOriginal`.
  4. **Physical iOS Device**: The mobile ImageIO parser strictly requires the explicit XML tag `<exif:DateTimeOriginal>` in the `http://ns.adobe.com/exif/1.0/` namespace, and requires ISO-8601 formatting (`YYYY-MM-DDThh:mm:ss±hh:mm`).
- **Fix**: Explicitly create and inject the tags using `CGImageMetadataSetTagWithPath`:
  ```swift
  let exifNamespace = "http://ns.adobe.com/exif/1.0/" as CFString
  let exifPrefix = "exif" as CFString
  let isoDateString = ISO8601DateFormatter().string(from: targetDate)

  if let tagOrig = CGImageMetadataTagCreate(exifNamespace, exifPrefix, "DateTimeOriginal" as CFString, .string, isoDateString as CFString) {
      CGImageMetadataSetTagWithPath(mutableMetadata, nil, "exif:DateTimeOriginal" as CFString, tagOrig)
  }
  if let tagDig = CGImageMetadataTagCreate(exifNamespace, exifPrefix, "DateTimeDigitized" as CFString, .string, isoDateString as CFString) {
      CGImageMetadataSetTagWithPath(mutableMetadata, nil, "exif:DateTimeDigitized" as CFString, tagDig)
  }
  ```

### 1.4 RAW / DNG Files: Apple ImageIO Omission of `OffsetTime` Tags
- **Symptom**: RAW `.DNG` photos (e.g. `IMG_0046.DNG` captured on iPhone) carry authentic timezone offsets (`+08:00`) in their metadata, yet the app marked them as having an **inferred** timezone instead of an authentic embedded timezone.
- **Root Cause**:
  1. Apple's `ImageIO` framework delegates decoding of RAW formats (DNG, CR2, NEF, ARW) to its `RawCamera.bundle` engine.
  2. When calling `CGImageSourceCopyPropertiesAtIndex(source, 0, nil)`, the returned `{Exif}` dictionary **completely drops** `OffsetTime` (tag `0x9010`), `OffsetTimeOriginal` (tag `0x9011`), and `OffsetTimeDigitized` (tag `0x9012`).
  3. Consequently, `offsetTimeStr` evaluated to `nil`, leading `exifTimeZone` to be `nil` and causing `hasEmbeddedTimeZone` to evaluate to `false` and `hasInferredTimeZone` to be `true`.
- **Solution**:
  1. Implemented a zero-copy binary TIFF IFD parser fallback in `ExifMetadataService.swift` (`findTIFFHeaderOffsets` & `parseRawExifOffsets`).
  2. For DNG/TIFF files, the TIFF header starts directly at byte 0 (`II*\0` or `MM\0*`), whereas JPEG files store it after `"Exif\0\0"`.
  3. The parser walks IFD0, locates the Exif SubIFD (tag `0x8769`), and directly extracts `0x9011` (`OffsetTimeOriginal`), `0x9010` (`OffsetTime`), or `0x9012` (`OffsetTimeDigitized`) ASCII values.
  4. Also unified `parseRawGPSIFD` to find TIFF headers at byte 0 or after `"Exif\0\0"`, enabling unrounded GPS extraction on DNG/TIFF files as well.
  5. In `extractImageRawDateAndGPSFields`, raw offset times are passed down and rendered in the EXIF inspector card.

---

## 2. PhotoKit Adjustments & Asset Extraction

### 2.1 Accessing Raw Unedited Assets
- When calling `PHImageManager.default().requestImageDataAndOrientation(for: ...)`, PhotoKit may bake in adjustments or downsample images.
- To read the true original asset bitstream:
  ```swift
  let resources = PHAssetResource.assetResources(for: asset)
  let photoRes = resources.first(where: { $0.type == .fullSizePhoto || $0.type == .photo })
  ```
  Load data directly using `PHAssetResourceManager.default().requestData(for: ...)`.

### 2.2 Decoding Photos App Adjustment Payloads
- Photos app adjustments are stored in `PHAdjustmentData` with format identifier `com.apple.photo`.
- The data payload is a zlib-compressed binary plist (`-15` raw deflate or standard zlib header).
- Decompressing this payload reveals adjustment filters:
  - `AdjustmentFormatVersion`
  - `SLT` (Semantic Line Tracker / Lighting)
  - `PortraitEffect` / `DepthEffect`
  - `AutoEnhance`
  - `CropAndRotate` (detects user rotation vs native camera orientation)

---

## 3. Samba (SMB2) Protocol Implementation

### 3.1 Subfolder Duplicate Renaming Bug
- **Bug**: When exporting to a subfolder (e.g. `2026/11`), if a file with the same name existed in the **root share folder**, `SambaService` erroneously renamed the file with ` (1)` before placing it in the subfolder.
- **Cause**: The service was fetching `existingFileSet` once for the root destination path and checking unique names against that root set.
- **Fix**: Implemented `subfolderFileSets: [String: Set<String>]`. Listing files is performed on-demand per effective target subpath (`destination.path + "\\" + itemSubfolder`). Duplicate checking is isolated strictly to the target subfolder.

### 3.2 Pure Swift SMB2 Client
- Uses raw BSD sockets over TCP port 445.
- Handles NTLMSSP Type 1, Type 2, and Type 3 messages.
- File writes split large buffers into 64 KB chunks (`maxWriteSize = 65536`) to adhere to standard SMB2 credit allocations and prevent server pipe disconnects.

### 3.3 Partial File Cleanup & Overwrite Conflict Resolution
- **Symptom**: If an SMB upload failed midway (e.g., network timeout, disconnection), the SMB server retained a corrupted partial file. When retrying the failed upload, the destination conflict check detected the partial file and renamed the retry attempt to `filename (1).ext`, creating duplicate and corrupted files in the destination.
- **Root Cause & Fixes**:
  1. **Immediate Remote Cleanup**: Added `deleteFile(relativePath:)` on `SMB2ClientSession` using `FILE_OPEN` (`disposition = 1`), `DELETE` access mask (`0x00010000`), and `FILE_DELETE_ON_CLOSE` (`0x00001060`). When an upload fails midway, `uploadFile` and `SambaService` immediately catch the failure and issue `deleteFile` on the partial remote path.
  2. **File Overwrite Disposition**: `SMB2Client`'s file creation uses `FILE_OVERWRITE_IF` (`disposition = 5`), ensuring that even if a partial or previous file remains on the server, opening the file automatically truncates it to 0 bytes and cleanly rewrites it in-place.
  3. **Preserving Pre-Computed Decisions**: Deduplication and conflict decisions are resolved definitively during the preview stage in `ExportSummarySheet`. In the execution phase (`startSambaExport`, `startExport`, `startGoogleDriveExport`) and subsequent retries (`retryFailedExports`), the conflict resolution defaults to `.overwrite` so retried items overwrite previous attempts cleanly instead of creating ` (N)` duplicates.

---

## 4. Google Drive API & Thumbnails

### 4.1 Authenticated Thumbnails
- Google Drive API returns `thumbnailLink` on file resources.
- Unlike public URLs, downloading these thumbnail images **requires the OAuth2 Bearer token**:
  ```swift
  var request = URLRequest(url: thumbnailURL)
  request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
  ```
  Fetching without the Authorization header results in an HTTP 401 or placeholder image.

---

## 5. SwiftUI Performance & Compiler Stability

### 5.1 Type-Checker Timeouts (`error: the compiler is unable to type-check this expression in reasonable time`)
- In complex views (e.g. `ExportDestinationSheet.swift` and `ExportSummarySheet.swift`), deeply nested `VStack`/`HStack` hierarchies with conditional bindings can cause the Swift type checker to exceed its time threshold.
- **Remedy**: Break large bodies into dedicated `@ViewBuilder` properties (e.g. `folderOrganizationSection`, `patternFloatingTrailingView`, `destinationHeaderCard`, `allClearCard`).

---

## 6. Physical Device Deployment & Tooling

### 6.1 Provisioning & Device Trust Notes
- If `xcrun devicectl device process launch` fails with:
  `FBSOpenApplicationErrorDomain error 7: Unable to launch because the device was not, or could not be, unlocked`
  The app is installed successfully; simply unlock your device screen.
- If launch fails with:
  `FBSOpenApplicationErrorDomain error 3: ... profile has not been explicitly trusted by the user`
  When a provisioning profile is renewed, iOS requires explicit trust: on the iPhone, go to **Settings > General > VPN & Device Management**, tap your developer certificate, and tap **"Trust"**.

### 6.2 Provisioning Profile Renewal
- To renew an expired team provisioning profile automatically via command line:
```bash
xcodebuild -scheme "Photo Exporter" -destination "generic/platform=iOS" -allowProvisioningUpdates build
```

---

## 8. Network Resilience, Upload Timeouts & Retry Architecture

### 8.1 Upload Timeout Root Causes & Avoidance in Slow Networks and Huge Files
- **Root Cause**: `URLSession.shared` has a default 60-second request timeout (`timeoutIntervalForRequest = 60.0`). When uploading large video assets (several hundred megabytes or gigabytes) or when operating over slow cellular/satellite networks, any network packet stall exceeding 60 seconds triggers `NSURLErrorTimedOut` (-1001), terminating the entire upload.
- **Solution**:
  1. Configured dedicated upload sessions with `timeoutIntervalForRequest = 300.0` (5 minutes packet inactivity timeout), `timeoutIntervalForResource = 7200.0` (2 hours total file transfer timeout), and `waitsForConnectivity = true`.
  2. For Google Drive, replaced multipart uploads with Google's official **Resumable Upload Protocol** (`uploadType=resumable`). This decouples metadata registration (POST) from binary streaming (PUT directly `fromFile: fileURL`), eliminating intermediate multipart temporary file construction and streaming file bytes directly to Google's dedicated upload URI.
  3. For Google Photos, streamed directly via the dedicated long-timeout upload session.

### 8.2 Retry Strategy & Transient Failure Classification
- Transient failures (e.g. `NSURLErrorTimedOut`, network connection lost, broken pipes, HTTP 429 rate limits, HTTP 500/502/503/504 server errors) are automatically detected via `isRetryableExportError(error)`.
- When an item hits a retryable error during export, the export services retry twice (3 attempts total: initial attempt + 2 retries) with exponential backoff (`Task.sleep` with backoff delay).
- Any items that permanently fail are stored in `progress.failedItems`. At the end of the export, the progress sheet surfaces a dedicated **"Retry X Failed Uploads"** button, allowing the user to retry all failed items without re-exporting already completed ones.

### 8.3 Deduplication Overrides and Interactive Renaming
- Deduplication tolerance allows up to **10% file size difference** when matching files in destination with the same base name and timestamp, accommodating metadata embedding overhead.
- In `ExportSummarySheet.swift`, users can interactively override deduplication decisions:
  - Marking a skipped file as **"Rename"** moves it from skipped to remaining, dynamically triggering `-N` suffix collision resolution.
  - Marking a renamed file as **"Skip"** moves it from export to skipped.

---

## 9. Export Cancellation Lifecycle & Sheet Presentation State Machine

### 9.1 The "Export Cancelled" Sheet Dismissal & Resurrection Race Conditions
- **Symptoms**:
  1. Occasionally, tapping "Cancel Export" in the Google Drive progress sheet caused the sheet to dismiss completely without showing the "Export Cancelled" status.
  2. Occasionally, after tapping "Cancel Export" and later tapping "Export" again to pick a destination, the old "Export Cancelled" sheet would suddenly pop up over the destination picker or summary sheet.
- **Root Cause**:
  1. `cancelExport()` in the view models previously called `isShowingExportProgress = false`, immediately initiating a UIKit/SwiftUI dismiss animation.
  2. Simultaneously, `activeExportTask?.cancel()` was dispatched to the background export worker.
  3. When `exportPhotos` finished unwinding from the cancellation (which took anywhere from ~50ms to 2-3 seconds depending on network tear-down), its completion block ran `self.isShowingExportProgress = true` unconditionally.
  4. If the background task finished while the sheet was mid-dismissal (~150ms), UIKit rejected the presentation (`Attempt to present while dismissal is in progress`), causing the sheet to vanish permanently.
  5. If the network request took 1-2 seconds to abort, the sheet had already dismissed, returning the user to the main screen. When the user re-tapped "Export" and selected a destination, the lingering completion block finally fired `self.isShowingExportProgress = true`, popping up the old cancelled sheet over the new destination flow.
  6. Furthermore, inside `exportPhotos`, catching `CancellationError` / `NSURLErrorCancelled` without an explicit early return treated cancellation as an upload error, incrementing `failureCount` and logging a false `"Upload failed: cancelled"` error message.
- **Solution**:
  1. **In-Place UI Transition**: In `cancelExport()`, do NOT set `isShowingExportProgress = false`. `ExportProgressView` was already designed with an in-place cancelled state (orange status icon, "Export Cancelled" title, and a "Done" button). Tapping "Cancel Export" simply sets `exportProgress.isCancelled = true` and `exportProgress.isExporting = false`, transitioning the visible sheet smoothly without dismiss/re-present cycles. The sheet only closes when the user taps "Done" (`finishExport()`).
  2. **Cancellation Guards in Task Completion**: The completion blocks of `activeExportTask` now check `guard !Task.isCancelled else { return }` and `if !self.exportProgress.isCancelled`, ensuring cancelled tasks never re-open the progress sheet or clobber newly started exports.
  3. **Clean Early Return in Export Services**: All export services (`GoogleDriveService`, `SambaService`, `ExportService`, `GooglePhotosService`) explicitly inspect `Task.isCancelled`, `CancellationError`, and `NSURLErrorCancelled` in their `catch` blocks to cleanly clean up temporary files, mark `isCancelled = true`, and return immediately without incrementing `failureCount` or logging false error messages.
  4. **Active Task Invalidation**: Before starting any new export, view models explicitly cancel and nil out any previous `activeExportTask`.
  - Recalculation is completely reactive and in-memory via `recalculatePlan()`.

---

## 10. SwiftUI Media Viewer, `AVPlayerViewController` & Fullscreen Transitions

### 10.1 Hosting `AVPlayerViewController` Directly (`DetailVideoPlayer`)
- **Symptom**: Embedding SwiftUI's `VideoPlayer` inside `NavigationStack` could trigger preference-propagation issues that hid the navigation bar when video loading failed or the player was torn down.
- **Solution**: `DetailVideoPlayer` in `PhotoDetailView.swift` wraps `AVPlayerViewController` directly via `UIViewControllerRepresentable` (sharing `DetailPlayerHostingBox` across inline and fullscreen mounts) and hooks its native full-screen control cleanly into `toggleFullScreen()`.

### 10.2 Fullscreen Landscape Transition vs. `UIWindowScene` Rotation Jumps
- **Symptom**: Triggering `UIWindowScene.requestGeometryUpdate` to switch from portrait to landscape while presenting SwiftUI's root hosting view caused `UIWindow` bounds/transform animations and SwiftUI layout updates to desync—shifting the entire root view hierarchy up and to the right on frame 1 of rotation. Splitting orientation into a delayed second step created an unwanted pause in portrait fullscreen.
- **Solution**:
  1. In `Photo_ExporterApp.swift`, `AppDelegate.setOrientationLock(_:preferredGeometry:)` only calls `requestGeometryUpdate` when `preferredGeometry != nil` or the current interface orientation is not permitted by `mask`.
  2. `PhotoDetailView.syncOrientationForFullScreen()` locks `AppDelegate.orientationLock` to the current interface orientation during fullscreen presentation, while `fullScreenOverlayView` animates the media container directly from `inlineMediaGlobalFrame` with a single `.spring(response: 0.34, dampingFraction: 0.88)` expansion and 90° rotation when viewing landscape media from a portrait screen.

### 10.3 `ZoomableImageView` Layout & Adjacent Slide Isolation
- **Finding**: Giving an inner `Image` explicit `containerSize` dimensions inside `ZoomableImageView` caused frame snaps during animated fullscreen transitions, while mounted adjacent slides (`-1` / `+1`) in `mediaDeck` could bleed at slide edges.
- **Solution**: `ZoomableImageView` uses `.frame(maxWidth: .infinity, maxHeight: .infinity)`, each `DetailMediaSlideView` applies `.clipped()`, and offscreen neighbor slides are unmounted while `isFullScreenTransitionActive` is `true` and `slideOffset == 0`.

---

## 11. Network Socket Resilience After App Backgrounding

- **Symptom**: Switching back to a Google Drive folder list after the app sat in the background could intermittently fail with `"Failed to load folder: The request timed out."` (`NSURLErrorTimedOut`).
- **Root Cause**: `URLSession.shared` holds keep-alive/HTTP/2 connections that iOS reclaims or stalls while suspended in the background, and its default tasks do not wait for connectivity or flush dead connections automatically on foreground resume.
- **Solution**:
  - `GoogleDriveAuthService` uses a dedicated connectivity-aware `apiSession` (`waitsForConnectivity = true`, `timeoutIntervalForRequest = 15.0`, `timeoutIntervalForResource = 60.0`) and flushes connections (`flush {}`) on `UIApplication.willEnterForegroundNotification` (mirrored on `GoogleDriveService`'s `uploadSession` and `streamingSession`).
  - Short Google Drive API and OAuth token-refresh requests use `GoogleDriveAuthService.performResilientDataRequest(_:maxAttempts:)`, which flushes stale sockets and retries retryable `URLError` failures with short backoff (without masking explicit `CancellationError` / `.cancelled`).

---

## 12. Startup Cache & Temporary Storage Hygiene

- **Finding**: Interrupted exports, remote downloads, and unpruned folder metadata caches accumulate in `Application Support/FolderCaches/` and `tmp/` over time.
- **Solution**: `Photo_ExporterApp.init()` triggers `MetadataCacheService.shared.performStartupStorageSweep(launchedAt:)`, which runs asynchronously to:
  1. Remove orphaned files from prior sessions in `FileManager.default.temporaryDirectory`.
  2. Remove obsolete debug artifacts in `Documents/`.
  3. Evict per-folder/remote caches under `Application Support/FolderCaches/` older than 30 days (`cacheTTL`), while keeping the Photo Library root metadata and list caches intact.

